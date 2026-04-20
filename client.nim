import std/[os, strutils, times]
import torrent, tracker, peer_wire, piece_manager

type
  TorrentClient* = ref object
    torrent*: TorrentFile
    peer_id*: string
    piece_manager*: PieceManager
    peers*: seq[PeerConnection]
    max_peers*: int

proc new_torrent_client*(torrent_file: string, max_peers: int = 30): TorrentClient =
  result = TorrentClient(
    torrent: parse_torrent(torrent_file),
    peer_id: generate_peer_id(),
    max_peers: max_peers,
    peers: @[]
  )
  
  result.piece_manager = new_piece_manager(result.torrent)
  
  echo "Torrent: ", result.torrent.name
  echo "Pieces: ", result.torrent.piece_count()
  echo "Piece length: ", result.torrent.piece_length
  echo "Total size: ", result.torrent.length, " bytes (", 
       result.torrent.length div (1024 * 1024), " MB)"

proc connect_to_peers(client: TorrentClient, tracker_peers: seq[Peer]) =
  var connected = 0
  
  for peer in tracker_peers:
    if connected >= client.max_peers:
      break
    
    try:
      let conn = connect_to_peer(peer, client.torrent.info_hash, client.peer_id)
      client.peers.add(conn)
      connected += 1
      
      let interested_msg = PeerMessage(msg_type: mt_interested)
      conn.send_message(interested_msg)
      conn.am_interested = true
      
    except CatchableError:
      discard

proc download_from_peer(client: TorrentClient, conn: PeerConnection): bool =
  result = false
  
  var peer_bitfield = conn.bitfield
  let piece_count = client.torrent.piece_count()
  
  if peer_bitfield.len == 0:
    peer_bitfield = new_seq[bool](piece_count)
  
  var setup_attempts = 0
  while conn.peer_choking and setup_attempts < 5:
    try:
      let msg = conn.receive_message()
      case msg.msg_type
      of mt_bitfield:
        peer_bitfield = conn.bitfield
      of mt_unchoke:
        discard
      of mt_have:
        if msg.piece_index < peer_bitfield.len:
          peer_bitfield[msg.piece_index] = true
      else:
        discard
    except PeerError:
      setup_attempts += 1
      continue
    except OSError:
      return false
    setup_attempts += 1
  
  if conn.peer_choking:
    return false
  
  # Download loop: pipeline requests and receive responses
  const MAX_PIPELINE = 10
  var in_flight = 0
  var idle_count = 0
  
  while not client.piece_manager.is_complete() and idle_count < 5:
    # Send as many requests as we can
    while in_flight < MAX_PIPELINE:
      try:
        let block_req = client.piece_manager.get_next_block(peer_bitfield)
        let request_msg = PeerMessage(
          msg_type: mt_request,
          req_index: block_req.piece_index,
          req_begin: block_req.begin,
          req_length: block_req.length
        )
        conn.send_message(request_msg)
        in_flight += 1
      except CatchableError:
        break
    
    if in_flight == 0:
      break
    
    # Receive a message
    try:
      let msg = conn.receive_message()
      
      case msg.msg_type
      of mt_piece:
        let success = client.piece_manager.add_block(msg.piece_idx, msg.piece_begin, msg.piece_data)
        if success:
          result = true
        in_flight -= 1
        idle_count = 0
      of mt_choke:
        break
      of mt_have:
        if msg.piece_index < peer_bitfield.len:
          peer_bitfield[msg.piece_index] = true
      of mt_unchoke:
        discard
      else:
        discard
    except PeerError:
      idle_count += 1
    except OSError:
      break

proc download*(client: TorrentClient) =
  echo "Starting download..."
  echo ""
  
  let left_bytes = client.torrent.length - client.piece_manager.bytes_downloaded()
  let tracker_response = announce_to_tracker(
    client.torrent, 
    client.peer_id, 
    6881, 0,
    client.piece_manager.bytes_downloaded(),
    left_bytes
  )
  
  if tracker_response.peers.len == 0:
    echo "No peers available"
    return
  
  connect_to_peers(client, tracker_response.peers)
  
  if client.peers.len == 0:
    echo "Could not connect to any peers"
    return
  
  echo "Connected to ", client.peers.len, " peers"
  echo ""
  
  let start_time = epoch_time()
  var last_progress = 0.0
  var stalled_rounds = 0
  
  while not client.piece_manager.is_complete() and stalled_rounds < 5:
    var made_progress = false
    
    # Filter out disconnected peers
    var active_peers: seq[PeerConnection] = @[]
    for conn in client.peers:
      if conn.socket != nil:
        active_peers.add(conn)
    client.peers = active_peers
    
    if client.peers.len == 0:
      echo "All peers disconnected"
      break
    
    for conn in client.peers:
      if client.piece_manager.is_complete():
        break
      
      discard download_from_peer(client, conn)
      
      let current_progress = client.piece_manager.progress()
      if current_progress > last_progress:
        made_progress = true
        let elapsed = epoch_time() - start_time
        let downloaded = client.piece_manager.bytes_downloaded()
        let speed = if elapsed > 0: downloaded.float / elapsed else: 0.0
        echo "Progress: ", (current_progress * 100).format_float(ff_decimal, 1), 
             "% (", downloaded div (1024 * 1024), " MB, ", 
             (speed / 1024.0).format_float(ff_decimal, 1), " KB/s)"
        last_progress = current_progress
    
    if not made_progress:
      stalled_rounds += 1
      echo "Stalled, retrying... (", stalled_rounds, "/5)"
      sleep(2000)
    else:
      stalled_rounds = 0
  
  if client.piece_manager.is_complete():
    let elapsed = epoch_time() - start_time
    echo ""
    echo "Download complete in ", elapsed.format_float(ff_decimal, 1), " seconds"
    client.piece_manager.write_files()
  else:
    echo ""
    echo "Download incomplete: ", (client.piece_manager.progress() * 100).format_float(ff_decimal, 1), "%"
  
  for conn in client.peers:
    conn.disconnect()
