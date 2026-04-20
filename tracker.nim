import std/[httpclient, strutils, uri, random, tables]
import bencode, torrent

type
  TrackerResponse* = object
    interval*: int
    peers*: seq[Peer]
    complete*: int
    incomplete*: int
  
  Peer* = object
    ip*: string
    port*: int
    id*: string
  
  TrackerError* = object of CatchableError

proc generate_peer_id*(): string =
  randomize()
  result = "-NIM001-"
  for i in 0..11:
    result &= char(rand(255))

proc url_encode(s: string): string =
  result = ""
  for c in s:
    if c.is_alpha_numeric() or c in ['-', '_', '.', '~']:
      result &= c
    else:
      result &= "%" & to_hex(ord(c), 2)

proc announce_to_tracker*(torrent: TorrentFile, peer_id: string, port: int = 6881, 
                         uploaded: int = 0, downloaded: int = 0, left: int = 0): TrackerResponse =
  let client = new_http_client(timeout = 15000)
  defer: client.close()
  
  var params = @[
    ("info_hash", url_encode(torrent.info_hash)),
    ("peer_id", url_encode(peer_id)),
    ("port", $port),
    ("uploaded", $uploaded),
    ("downloaded", $downloaded),
    ("left", $left),
    ("compact", "1"),
    ("event", "started")
  ]
  
  var announce_url = torrent.announce & "?"
  for i, (key, value) in params:
    if i > 0: announce_url &= "&"
    announce_url &= key & "=" & value
  
  echo "Contacting tracker..."
  
  let response = client.get_content(announce_url)
  let decoded = parse_bencode(response)
  
  if decoded.kind != bk_dict:
    raise new_exception(TrackerError, "Invalid tracker response")
  
  let tracker_dict = decoded.dict_val
  
  # Check for failure reason
  if "failure reason" in tracker_dict:
    if tracker_dict["failure reason"].kind == bk_string:
      raise new_exception(TrackerError, "Tracker error: " & tracker_dict["failure reason"].str_val)
  
  # Parse interval
  if "interval" in tracker_dict and tracker_dict["interval"].kind == bk_int:
    result.interval = tracker_dict["interval"].int_val
  else:
    result.interval = 1800  # Default 30 minutes
  
  # Parse complete/incomplete
  if "complete" in tracker_dict and tracker_dict["complete"].kind == bk_int:
    result.complete = tracker_dict["complete"].int_val
  
  if "incomplete" in tracker_dict and tracker_dict["incomplete"].kind == bk_int:
    result.incomplete = tracker_dict["incomplete"].int_val
  
  # Parse peers (compact format)
  if "peers" notin tracker_dict:
    raise new_exception(TrackerError, "No peers in tracker response")
  
  result.peers = @[]
  
  if tracker_dict["peers"].kind == bk_string:
    # Compact format: 6 bytes per peer (4 for IP, 2 for port)
    let peers_data = tracker_dict["peers"].str_val
    
    if peers_data.len mod 6 != 0:
      raise new_exception(TrackerError, "Invalid peers data length")
    
    var i = 0
    while i < peers_data.len:
      var peer = Peer()
      
      # Extract IP address (4 bytes)
      let ip1 = ord(peers_data[i])
      let ip2 = ord(peers_data[i+1])
      let ip3 = ord(peers_data[i+2])
      let ip4 = ord(peers_data[i+3])
      peer.ip = $ip1 & "." & $ip2 & "." & $ip3 & "." & $ip4
      
      # Extract port (2 bytes, big-endian)
      let port_high = ord(peers_data[i+4])
      let port_low = ord(peers_data[i+5])
      peer.port = (port_high shl 8) or port_low
      
      peer.id = ""  # Not provided in compact format
      
      result.peers.add(peer)
      i += 6
  
  elif tracker_dict["peers"].kind == bk_list:
    # Dictionary format (less common)
    for peer_item in tracker_dict["peers"].list_val:
      if peer_item.kind != bk_dict:
        continue
      
      let peer_dict = peer_item.dict_val
      var peer = Peer()
      
      if "ip" in peer_dict and peer_dict["ip"].kind == bk_string:
        peer.ip = peer_dict["ip"].str_val
      
      if "port" in peer_dict and peer_dict["port"].kind == bk_int:
        peer.port = peer_dict["port"].int_val
      
      if "peer id" in peer_dict and peer_dict["peer id"].kind == bk_string:
        peer.id = peer_dict["peer id"].str_val
      
      if peer.ip != "" and peer.port != 0:
        result.peers.add(peer)
  
  else:
    raise TrackerError.new_exception("Invalid peers format in tracker response")
  
  echo "Found ", result.peers.len, " peers (", result.complete, " seeders, ", result.incomplete, " leechers)"
