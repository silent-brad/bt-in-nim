import std/[net, nativesockets, posix]
import tracker

type
  PeerConnection* = ref object
    socket*: Socket
    peer*: Peer
    am_choking*: bool
    am_interested*: bool
    peer_choking*: bool
    peer_interested*: bool
    bitfield*: seq[bool]
  
  Message_type* = enum
    mt_choke = 0
    mt_unchoke = 1
    mt_interested = 2
    mt_not_interested = 3
    mt_have = 4
    mt_bitfield = 5
    mt_request = 6
    mt_piece = 7
    mt_cancel = 8
  
  PeerMessage* = object
    case msg_type*: MessageType
    of mt_have:
      piece_index*: int
    of mt_bitfield:
      bitfield*: string
    of mt_request, mt_cancel:
      req_index*: int
      req_begin*: int
      req_length*: int
    of mt_piece:
      piece_idx*: int
      piece_begin*: int
      piece_data*: string
    else:
      discard
  
  PeerError* = object of CatchableError

proc recv_exact(socket: Socket, size: int): string =
  result = new_string_of_cap(size)
  var remaining = size
  while remaining > 0:
    let chunk = socket.recv(remaining)
    if chunk.len == 0:
      raise new_exception(PeerError, "Connection closed")
    result.add(chunk)
    remaining -= chunk.len

const HANDSHAKE_PSTR = "BitTorrent protocol"

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
  var handshake = new_string_of_cap(68)
  
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
  let pstr_len_data = conn.socket.recv_exact(1)
  let pstr_len = ord(pstr_len_data[0])
  
  let protocol = conn.socket.recv_exact(pstr_len)
  if protocol != HANDSHAKE_PSTR:
    raise new_exception(PeerError, "Invalid protocol: " & protocol)
  
  discard conn.socket.recv_exact(8)
  
  let info_hash = conn.socket.recv_exact(20)
  let peer_id = conn.socket.recv_exact(20)
  
  result = (info_hash, peer_id)

proc int_to_bytes(value: int, size: int): string =
  result = new_string(size)
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
  of mt_choke:
    message = int_to_bytes(1, 4) & char(0)
  of mt_unchoke:
    message = int_to_bytes(1, 4) & char(1)
  of mt_interested:
    message = int_to_bytes(1, 4) & char(2)
  of mt_not_interested:
    message = int_to_bytes(1, 4) & char(3)
  of mt_have:
    message = int_to_bytes(5, 4) & char(4) & int_to_bytes(msg.piece_index, 4)
  of mt_bitfield:
    let payload_len = 1 + msg.bitfield.len
    message = int_to_bytes(payload_len, 4) & char(5) & msg.bitfield
  of mt_request:
    message = int_to_bytes(13, 4) & char(6) &
              int_to_bytes(msg.req_index, 4) &
              int_to_bytes(msg.req_begin, 4) &
              int_to_bytes(msg.req_length, 4)
  of mt_piece:
    let payload_len = 9 + msg.piece_data.len
    message = int_to_bytes(payload_len, 4) & char(7) &
              int_to_bytes(msg.piece_idx, 4) &
              int_to_bytes(msg.piece_begin, 4) &
              msg.piece_data
  of mt_cancel:
    message = int_to_bytes(13, 4) & char(8) &
              int_to_bytes(msg.req_index, 4) &
              int_to_bytes(msg.req_begin, 4) &
              int_to_bytes(msg.req_length, 4)
  
  conn.socket.send(message)

proc receive_message*(conn: PeerConnection): PeerMessage =
  let length_data = conn.socket.recv_exact(4)
  let length = bytes_to_int(length_data)
  
  if length == 0:
    return conn.receive_message()
  
  let msg_type_data = conn.socket.recv_exact(1)
  let msg_type_int = ord(msg_type_data[0])
  
  let payload_len = length - 1
  let payload = if payload_len > 0: conn.socket.recv_exact(payload_len) else: ""
  
  if msg_type_int < ord(low(MessageType)) or msg_type_int > ord(high(MessageType)):
    raise new_exception(PeerError, "Unknown message type: " & $msg_type_int)
  
  let msg_type = MessageType(msg_type_int)
  
  case msg_type
  of mt_choke:
    conn.peer_choking = true
    result = PeerMessage(msg_type: mt_choke)
  of mt_unchoke:
    conn.peer_choking = false
    result = PeerMessage(msg_type: mt_unchoke)
  of mt_interested:
    conn.peer_interested = true
    result = PeerMessage(msg_type: mt_interested)
  of mt_not_interested:
    conn.peer_interested = false
    result = PeerMessage(msg_type: mt_not_interested)
  of mt_have:
    if payload.len != 4:
      raise new_exception(PeerError, "Invalid have message")
    let piece_index = bytes_to_int(payload)
    result = PeerMessage(msg_type: mt_have, piece_index: piece_index)
  of mt_bitfield:
    result = PeerMessage(msg_type: mt_bitfield, bitfield: payload)
    conn.bitfield = @[]
    for byte_val in payload:
      for bit in 0..7:
        let has_piece = (ord(byte_val) and (1 shl (7 - bit))) != 0
        conn.bitfield.add(has_piece)
  of mt_request:
    if payload.len != 12:
      raise new_exception(PeerError, "Invalid request message")
    let index = bytes_to_int(payload[0..3])
    let begin = bytes_to_int(payload[4..7])
    let req_length = bytes_to_int(payload[8..11])
    result = PeerMessage(msg_type: mt_request, req_index: index, req_begin: begin, req_length: req_length)
  of mt_piece:
    if payload.len < 8:
      raise new_exception(PeerError, "Invalid piece message")
    let index = bytes_to_int(payload[0..3])
    let begin = bytes_to_int(payload[4..7])
    let data = payload[8..^1]
    result = PeerMessage(msg_type: mt_piece, piece_idx: index, piece_begin: begin, piece_data: data)
  of mt_cancel:
    if payload.len != 12:
      raise new_exception(PeerError, "Invalid cancel message")
    let index = bytes_to_int(payload[0..3])
    let begin = bytes_to_int(payload[4..7])
    let req_length = bytes_to_int(payload[8..11])
    result = PeerMessage(msg_type: mt_cancel, req_index: index, req_begin: begin, req_length: req_length)

proc connect_with_timeout(socket: Socket, address: string, port: Port, timeout_ms: int) =
  let fd = socket.get_fd()
  fd.set_blocking(false)
  
  try:
    socket.connect(address, port)
  except OSError:
    var wfds: TFdSet
    FD_ZERO(wfds)
    FD_SET(fd, wfds)
    var tv = Timeval(tv_sec: posix.Time(timeout_ms div 1000), 
                     tv_usec: Suseconds((timeout_ms mod 1000) * 1000))
    let ret = select(fd.cint + 1, nil, addr wfds, nil, addr tv)
    if ret <= 0:
      raise new_exception(PeerError, "Connection timed out")
    
    var err: cint
    var err_len = SockLen(sizeof(err))
    discard posix.getsockopt(fd, SOL_SOCKET, SO_ERROR, addr err, addr err_len)
    if err != 0:
      raise new_exception(PeerError, "Connection failed")
  
  fd.set_blocking(true)

proc connect_to_peer*(peer: Peer, info_hash: string, peer_id: string): PeerConnection =
  result = new_peer_connection(peer)
  
  result.socket = new_socket()
  var tv = Timeval(tv_sec: posix.Time(5), tv_usec: Suseconds(0))
  discard posix.setsockopt(result.socket.get_fd(), SOL_SOCKET, SO_RCVTIMEO, addr tv, SockLen(sizeof(tv)))
  discard posix.setsockopt(result.socket.get_fd(), SOL_SOCKET, SO_SNDTIMEO, addr tv, SockLen(sizeof(tv)))
  
  connect_with_timeout(result.socket, peer.ip, Port(peer.port), 5000)
  
  result.send_handshake(info_hash, peer_id)
  
  let (received_hash, _) = result.receive_handshake()
  
  if received_hash != info_hash:
    raise new_exception(PeerError, "Info hash mismatch")

proc disconnect*(conn: PeerConnection) =
  if conn.socket != nil:
    conn.socket.close()

proc has_piece*(conn: PeerConnection, piece_index: int): bool =
  if piece_index < 0 or piece_index >= conn.bitfield.len:
    return false
  return conn.bitfield[piece_index]
