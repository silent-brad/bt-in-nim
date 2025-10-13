import std/[net, streams, strutils, endians]
import tracker, torrent

type
  PeerConnection* = ref object
    socket*: Socket
    peer*: Peer
    am_choking*: bool
    am_interested*: bool
    peer_choking*: bool
    peer_interested*: bool
    bitfield*: seq[bool]
  
  MessageType* = enum
    mtChoke = 0
    mtUnchoke = 1
    mtInterested = 2
    mtNotInterested = 3
    mtHave = 4
    mtBitfield = 5
    mtRequest = 6
    mtPiece = 7
    mtCancel = 8
  
  PeerMessage* = object
    case msg_type*: MessageType
    of mtHave:
      piece_index*: int
    of mtBitfield:
      bitfield*: string
    of mtRequest, mtCancel:
      req_index*: int
      req_begin*: int
      req_length*: int
    of mtPiece:
      piece_idx*: int
      piece_begin*: int
      piece_data*: string
    else:
      discard
  
  PeerError* = object of CatchableError

const HANDSHAKE_PSTR = "BitTorrent protocol"
const BLOCK_SIZE = 16384  # 16KB blocks

proc new_peer_connection*(peer: Peer): PeerConnection =
  result = PeerConnection(
    peer: peer,
    am_choking: true,
    am_interested: false,
    peer_choking: true,
    peer_interested: false,
    bitfield: @[]
  )

proc send_handshake*(conn: PeerConnection, info_hash: string, peer_id: string) =
  var handshake = newStringOfCap(68)
  
  # Protocol string length (1 byte)
  handshake &= char(HANDSHAKE_PSTR.len)
  
  # Protocol string
  handshake &= HANDSHAKE_PSTR
  
  # Reserved bytes (8 bytes)
  for i in 0..7:
    handshake &= char(0)
  
  # Info hash (20 bytes)
  handshake &= info_hash
  
  # Peer ID (20 bytes)
  handshake &= peer_id
  
  conn.socket.send(handshake)

proc receive_handshake*(conn: PeerConnection): (string, string) =
  # Read protocol string length
  let pstr_len_data = conn.socket.recv(1)
  if pstr_len_data.len != 1:
    raise newException(PeerError, "Failed to read protocol string length")
  
  let pstr_len = ord(pstr_len_data[0])
  
  # Read protocol string
  let protocol = conn.socket.recv(pstr_len)
  if protocol.len != pstr_len:
    raise newException(PeerError, "Failed to read protocol string")
  
  if protocol != HANDSHAKE_PSTR:
    raise newException(PeerError, "Invalid protocol: " & protocol)
  
  # Read reserved bytes (8 bytes)
  let reserved = conn.socket.recv(8)
  if reserved.len != 8:
    raise newException(PeerError, "Failed to read reserved bytes")
  
  # Read info hash (20 bytes)
  let info_hash = conn.socket.recv(20)
  if info_hash.len != 20:
    raise newException(PeerError, "Failed to read info hash")
  
  # Read peer ID (20 bytes)
  let peer_id = conn.socket.recv(20)
  if peer_id.len != 20:
    raise newException(PeerError, "Failed to read peer ID")
  
  result = (info_hash, peer_id)

proc int_to_bytes(value: int, size: int): string =
  result = newString(size)
  var val = value
  for i in countdown(size-1, 0):
    result[i] = char(val and 0xFF)
    val = val shr 8

proc bytes_to_int(data: string): int =
  result = 0
  for i in 0..<data.len:
    result = (result shl 8) or ord(data[i])

proc send_message*(conn: PeerConnection, msg: PeerMessage) =
  var message = ""
  
  case msg.msg_type
  of mtChoke:
    message = int_to_bytes(1, 4) & char(0)
  of mtUnchoke:
    message = int_to_bytes(1, 4) & char(1)
  of mtInterested:
    message = int_to_bytes(1, 4) & char(2)
  of mtNotInterested:
    message = int_to_bytes(1, 4) & char(3)
  of mtHave:
    message = int_to_bytes(5, 4) & char(4) & int_to_bytes(msg.piece_index, 4)
  of mtBitfield:
    let payload_len = 1 + msg.bitfield.len
    message = int_to_bytes(payload_len, 4) & char(5) & msg.bitfield
  of mtRequest:
    message = int_to_bytes(13, 4) & char(6) &
              int_to_bytes(msg.req_index, 4) &
              int_to_bytes(msg.req_begin, 4) &
              int_to_bytes(msg.req_length, 4)
  of mtPiece:
    let payload_len = 9 + msg.piece_data.len
    message = int_to_bytes(payload_len, 4) & char(7) &
              int_to_bytes(msg.piece_idx, 4) &
              int_to_bytes(msg.piece_begin, 4) &
              msg.piece_data
  of mtCancel:
    message = int_to_bytes(13, 4) & char(8) &
              int_to_bytes(msg.req_index, 4) &
              int_to_bytes(msg.req_begin, 4) &
              int_to_bytes(msg.req_length, 4)
  
  conn.socket.send(message)

proc receive_message*(conn: PeerConnection): PeerMessage =
  # Read message length (4 bytes)
  let length_data = conn.socket.recv(4)
  if length_data.len != 4:
    raise newException(PeerError, "Failed to read message length")
  
  let length = bytes_to_int(length_data)
  
  if length == 0:
    # Keep-alive message
    raise newException(PeerError, "Keep-alive message")
  
  # Read message type (1 byte)
  let msg_type_data = conn.socket.recv(1)
  if msg_type_data.len != 1:
    raise newException(PeerError, "Failed to read message type")
  
  let msg_type_int = ord(msg_type_data[0])
  let msg_type = MessageType(msg_type_int)
  
  # Read payload
  let payload_len = length - 1
  let payload = if payload_len > 0: conn.socket.recv(payload_len) else: ""
  
  if payload.len != payload_len:
    raise newException(PeerError, "Failed to read message payload")
  
  case msg_type
  of mtChoke:
    conn.peer_choking = true
    result = PeerMessage(msg_type: mtChoke)
  of mtUnchoke:
    conn.peer_choking = false
    result = PeerMessage(msg_type: mtUnchoke)
  of mtInterested:
    conn.peer_interested = true
    result = PeerMessage(msg_type: mtInterested)
  of mtNotInterested:
    conn.peer_interested = false
    result = PeerMessage(msg_type: mtNotInterested)
  of mtHave:
    if payload.len != 4:
      raise newException(PeerError, "Invalid have message")
    let piece_index = bytes_to_int(payload)
    result = PeerMessage(msg_type: mtHave, piece_index: piece_index)
  of mtBitfield:
    result = PeerMessage(msg_type: mtBitfield, bitfield: payload)
    # Parse bitfield
    conn.bitfield = @[]
    for byte_val in payload:
      for bit in 0..7:
        let has_piece = (ord(byte_val) and (1 shl (7 - bit))) != 0
        conn.bitfield.add(has_piece)
  of mtRequest:
    if payload.len != 12:
      raise newException(PeerError, "Invalid request message")
    let index = bytes_to_int(payload[0..3])
    let begin = bytes_to_int(payload[4..7])
    let req_length = bytes_to_int(payload[8..11])
    result = PeerMessage(msg_type: mtRequest, req_index: index, req_begin: begin, req_length: req_length)
  of mtPiece:
    if payload.len < 8:
      raise newException(PeerError, "Invalid piece message")
    let index = bytes_to_int(payload[0..3])
    let begin = bytes_to_int(payload[4..7])
    let data = payload[8..^1]
    result = PeerMessage(msg_type: mtPiece, piece_idx: index, piece_begin: begin, piece_data: data)
  of mtCancel:
    if payload.len != 12:
      raise newException(PeerError, "Invalid cancel message")
    let index = bytes_to_int(payload[0..3])
    let begin = bytes_to_int(payload[4..7])
    let req_length = bytes_to_int(payload[8..11])
    result = PeerMessage(msg_type: mtCancel, req_index: index, req_begin: begin, req_length: req_length)

proc connect_to_peer*(peer: Peer, info_hash: string, peer_id: string): PeerConnection =
  result = new_peer_connection(peer)
  
  result.socket = newSocket()
  result.socket.connect(peer.ip, Port(peer.port))
  
  # Send handshake
  result.send_handshake(info_hash, peer_id)
  
  # Receive handshake
  let (received_hash, received_id) = result.receive_handshake()
  
  if received_hash != info_hash:
    raise newException(PeerError, "Info hash mismatch")
  
  echo "Connected to peer: ", peer.ip, ":", peer.port

proc disconnect*(conn: PeerConnection) =
  if conn.socket != nil:
    conn.socket.close()

proc has_piece*(conn: PeerConnection, piece_index: int): bool =
  if piece_index < 0 or piece_index >= conn.bitfield.len:
    return false
  return conn.bitfield[piece_index]
