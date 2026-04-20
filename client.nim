import std/[os, asyncdispatch, asyncnet, net, strutils, times, random]
import torrent, tracker, peer_wire, piece_manager

type
  TorrentClient* = ref object
    torrent*: Torrent_file
    peer_id*: string
    piece_manager*: Piece_manager
    peers*: seq[PeerConnection]
    max_peers*: int

proc new_torrent_client*(torrent_file: string, max_peers: int = 50): TorrentClient =
  result = TorrentClient(
    torrent: parse_torrent(torrent_file),
    peer_id: generate_peer_id(),
    max_peers: max_peers,
    peers: @[]
  )
  
  result.piece_manager = new_piece_manager(result.torrent)
  
  echo "Torrent: ", result.torrent.name
  echo "Pieces: ", result.torrent.piece_count()
  echo "Total size: ", result.torrent.length, " bytes"

proc connect_to_peers(client: TorrentClient, tracker_peers: seq[Peer]) =
  var connected = 0
  
  for peer in tracker_peers:
    if connected >= client.max_peers:
      break
    
    try:
      echo "Attempting to connect to peer: ", peer.ip, ":", peer.port
      let conn = connect_to_peer(peer, client.torrent.info_hash, client.peer_id)
      client.peers.add(conn)
      connected += 1
      
      # Send interested message
      let interested_msg = PeerMessage(msg_type: mt_interested)
      conn.send_message(interested_msg)
      conn.am_interested = true
      
      echo "Successfully connected to peer ", peer.ip, ":", peer.port
      
    except PeerError as e:
      echo "Failed to connect to peer ", peer.ip, ":", peer.port, ": ", e.msg
    except OSError as e:
      echo "Network error connecting to peer ", peer.ip, ":", peer.port, ": ", e.msg
    
    sleep(100)  # Brief delay between connections

proc download_from_peer(client: TorrentClient, conn: PeerConnection) =
  try:
    # First, try to receive the bitfield
    var received_bitfield = false
    var peer_bitfield: seq[bool] = @[]
    
    # Wait for bitfield or other messages
    var attempts = 0
    while not received_bitfield and attempts < 10:
      try:
        let msg = conn.receive_message()
        
        case msg.msg_type
        of mt_bitfield:
          received_bitfield = true
          peer_bitfield = conn.bitfield
          echo "Received bitfield from peer ", conn.peer.ip, " with ", peer_bitfield.len, " pieces"
        of mt_unchoke:
          echo "Peer ", conn.peer.ip, " unchoked us"
        of mt_choke:
          echo "Peer ", conn.peer.ip, " choked us"
        of mt_have:
          echo "Peer ", conn.peer.ip, " has piece ", msg.piece_index
          if msg.piece_index < peer_bitfield.len:
            peer_bitfield[msg.piece_index] = true
        else:
          echo "Received message type ", msg.msg_type, " from peer ", conn.peer.ip
        
        attempts += 1
      except PeerError:
        attempts += 1
        sleep(500)
    
    if not received_bitfield:
      echo "No bitfield received from peer ", conn.peer.ip
      return
    
    # Start requesting pieces
    var active_requests = 0
    const MAX_REQUESTS = 10
    
    while not client.piece_manager.is_complete() and active_requests < MAX_REQUESTS:
      try:
        if conn.peer_choking:
          # Wait for unchoke or try to receive messages
          try:
            let msg = conn.receive_message()
            case msg.msg_type
            of mt_unchoke:
              echo "Peer ", conn.peer.ip, " unchoked us"
            of mt_choke:
              echo "Peer ", conn.peer.ip, " choked us"
              break
            of mt_have:
              if msg.piece_index < peer_bitfield.len:
                peer_bitfield[msg.piece_index] = true
            of mt_piece:
              # Unexpected piece data
              let success = client.piece_manager.add_block(msg.piece_idx, msg.piece_begin, msg.piece_data)
              if success:
                echo "Received block for piece ", msg.piece_idx, " from peer ", conn.peer.ip
                active_requests -= 1
            else:
              discard
          except PeerError:
            break
          
          continue
        
        # Try to get next block to request
        try:
          let block_req = client.piece_manager.get_next_block(peer_bitfield)
          
          # Send request
          let request_msg = PeerMessage(
            msg_type: mt_request,
            req_index: block_req.piece_index,
            req_begin: block_req.begin,
            req_length: block_req.length
          )
          
          conn.send_message(request_msg)
          active_requests += 1
          
          echo "Requested piece ", block_req.piece_index, " block at ", block_req.begin, " from peer ", conn.peer.ip
          
        except Catchable_error:
          # No more blocks available from this peer
          break
        
        # Try to receive response
        try:
          let msg = conn.receive_message()
          
          case msg.msg_type
          of mt_piece:
            let success = client.piece_manager.add_block(msg.piece_idx, msg.piece_begin, msg.piece_data)
            if success:
              echo "Received block for piece ", msg.piece_idx, " from peer ", conn.peer.ip
            active_requests -= 1
          
          of mt_choke:
            echo "Peer ", conn.peer.ip, " choked us"
            break
          
          of mt_have:
            if msg.piece_index < peer_bitfield.len:
              peer_bitfield[msg.piece_index] = true
          
          else:
            echo "Received message type ", msg.msg_type, " from peer ", conn.peer.ip
        
        except PeerError:
          # Timeout or connection issue
          break
      
      except Exception as e:
        echo "Error downloading from peer ", conn.peer.ip, ": ", e.msg
        break
  
  except Exception as e:
    echo "Fatal error with peer ", conn.peer.ip, ": ", e.msg
  
  finally:
    conn.disconnect()

proc download*(client: TorrentClient) =
  echo "Starting download for torrent: ", client.torrent.name
  
  try:
    # Contact tracker
    let left_bytes = client.torrent.length - client.piece_manager.bytes_downloaded()
    let tracker_response = announce_to_tracker(
      client.torrent, 
      client.peer_id, 
      6881,
      0,  # uploaded
      client.piece_manager.bytes_downloaded(),  # downloaded
      left_bytes  # left
    )
    
    echo "Tracker returned ", tracker_response.peers.len, " peers"
    
    if tracker_response.peers.len == 0:
      echo "No peers available"
      return
    
    # Connect to peers
    connect_to_peers(client, tracker_response.peers)
    
    if client.peers.len == 0:
      echo "Could not connect to any peers"
      return
    
    echo "Connected to ", client.peers.len, " peers"
    
    # Download from peers (simplified single-threaded approach)
    var last_progress = 0.0
    var stalled_count = 0
    
    while not client.piece_manager.is_complete() and stalled_count < 30:
      var made_progress = false
      
      for conn in client.peers:
        if client.piece_manager.is_complete():
          break
        
        download_from_peer(client, conn)
        
        let current_progress = client.piece_manager.progress()
        if current_progress > last_progress:
          made_progress = true
          last_progress = current_progress
          echo "Progress: ", (current_progress * 100).format_float(ff_decimal, 1), "%"
      
      if not made_progress:
        stalled_count += 1
        echo "Download stalled, attempt ", stalled_count, "/30"
        sleep(2000)  # Wait 2 seconds before retry
      else:
        stalled_count = 0
    
    if client.piece_manager.is_complete():
      echo "Download completed successfully!"
      client.piece_manager.write_files()
    else:
      echo "Download incomplete. Progress: ", (client.piece_manager.progress() * 100).format_float(ff_decimal, 1), "%"
    
  except Exception as e:
    echo "Download failed: ", e.msg
  
  finally:
    # Cleanup connections
    for conn in client.peers:
      conn.disconnect()
