import std/[tables, sets, sha1, os, strutils]
import torrent

type
  PieceManager* = ref object
    torrent*: Torrent_file
    pieces*: seq[PieceState]
    completed_pieces*: Hash_set[int]
    in_flight*: Hash_set[int64]
    downloaded_data*: Table[int, string]
  
  PieceState* = object
    index*: int
    downloaded*: bool
    verified*: bool
    blocks*: seq[BlockState]
  
  BlockState* = object
    begin*: int
    length*: int
    downloaded*: bool
    data*: string
  
  BlockRequest* = object
    piece_index*: int
    begin*: int
    length*: int
    peer*: string

const BLOCK_SIZE = 16384  # 16KB

proc new_piece_manager*(torrent: Torrent_file): PieceManager =
  result = PieceManager(
    torrent: torrent,
    pieces: @[],
    completed_pieces: init_hash_set[int](),
    in_flight: init_hash_set[int64](),
    downloaded_data: init_table[int, string]()
  )
  
  # Initialize pieces
  let piece_count = torrent.piece_count()
  for i in 0..<piece_count:
    var piece = PieceState(
      index: i,
      downloaded: false,
      verified: false,
      blocks: @[]
    )
    
    let piece_size = torrent.piece_size(i)
    var offset = 0
    
    # Split piece into blocks
    while offset < piece_size:
      let block_size = min(BLOCK_SIZE, piece_size - offset)
      piece.blocks.add(BlockState(
        begin: offset,
        length: block_size,
        downloaded: false,
        data: ""
      ))
      offset += block_size
    
    result.pieces.add(piece)

proc sha1_raw(data: string): string =
  let digest = Sha1Digest(secure_hash(data))
  result = new_string(20)
  for i in 0..<20:
    result[i] = char(digest[i])

proc block_key(piece_index: int, begin: int): int64 =
  (piece_index.int64 shl 32) or begin.int64

proc get_next_block*(pm: PieceManager, peer_pieces: seq[bool]): BlockRequest =
  for piece_idx in 0..<pm.pieces.len:
    if piece_idx >= peer_pieces.len or not peer_pieces[piece_idx]:
      continue
    
    if piece_idx in pm.completed_pieces:
      continue
    
    let piece = pm.pieces[piece_idx]
    
    for blk in piece.blocks:
      if not blk.downloaded and block_key(piece_idx, blk.begin) notin pm.in_flight:
        pm.in_flight.incl(block_key(piece_idx, blk.begin))
        return BlockRequest(
          piece_index: piece_idx,
          begin: blk.begin,
          length: blk.length,
          peer: ""
        )
  
  raise new_exception(Catchable_error, "No blocks available")

proc add_block*(pm: PieceManager, piece_index: int, begin: int, data: string): bool =
  if piece_index < 0 or piece_index >= pm.pieces.len:
    return false
  
  var piece = addr pm.pieces[piece_index]
  
  pm.in_flight.excl(block_key(piece_index, begin))
  
  for i in 0..<piece.blocks.len:
    if piece.blocks[i].begin == begin:
      if piece.blocks[i].downloaded:
        return false
      
      piece.blocks[i].data = data
      piece.blocks[i].downloaded = true
      
      # Check if all blocks in this piece are downloaded
      var all_downloaded = true
      for blk in piece.blocks:
        if not blk.downloaded:
          all_downloaded = false
          break
      
      if all_downloaded:
        # Verify the piece
        var piece_data = ""
        for blk in piece.blocks:
          piece_data &= blk.data
        
        let expected_hash = pm.torrent.piece_hash(piece_index)
        let actual_hash = sha1_raw(piece_data)
        
        if actual_hash == expected_hash:
          piece.verified = true
          piece.downloaded = true
          pm.completed_pieces.incl(piece_index)
          pm.downloaded_data[piece_index] = piece_data
          
          let pct = (pm.completed_pieces.len.float / pm.pieces.len.float * 100.0)
          echo "Piece ", piece_index, " verified (", pm.completed_pieces.len, "/", pm.pieces.len, " - ", pct.format_float(ff_decimal, 1), "%)"
          return true
        else:
          echo "Piece ", piece_index, " failed verification"
          for j in 0..<piece.blocks.len:
            piece.blocks[j].downloaded = false
            piece.blocks[j].data = ""
            pm.in_flight.excl(block_key(piece_index, piece.blocks[j].begin))
          return false
      
      return true
  
  return false

proc is_piece_complete*(pm: PieceManager, piece_index: int): bool =
  if piece_index < 0 or piece_index >= pm.pieces.len:
    return false
  
  return piece_index in pm.completed_pieces

proc progress*(pm: PieceManager): float =
  if pm.pieces.len == 0:
    return 0.0
  
  return pm.completed_pieces.len.float / pm.pieces.len.float

proc bytes_downloaded*(pm: PieceManager): int =
  result = 0
  for piece_index in pm.completed_pieces:
    result += pm.torrent.piece_size(piece_index)

proc is_complete*(pm: PieceManager): bool =
  return pm.completed_pieces.len == pm.pieces.len

proc get_piece_data*(pm: PieceManager, piece_index: int): string =
  if piece_index in pm.downloaded_data:
    return pm.downloaded_data[piece_index]
  return ""

proc needed_pieces*(pm: PieceManager): seq[int] =
  result = @[]
  for i in 0..<pm.pieces.len:
    if i notin pm.completed_pieces:
      result.add(i)

proc has_piece*(pm: PieceManager, piece_index: int): bool =
  return piece_index in pm.completed_pieces

proc write_files*(pm: PieceManager, output_dir: string = ".") =
  if not pm.is_complete():
    echo "Download not complete, cannot write files"
    return
  
  var all_data = ""
  for i in 0..<pm.pieces.len:
    all_data &= pm.get_piece_data(i)
  
  if pm.torrent.files.len == 0:
    let filename = join_path(output_dir, pm.torrent.name)
    write_file(filename, all_data[0..<pm.torrent.length])
    echo "Wrote file: ", filename
  else:
    let base_dir = join_path(output_dir, pm.torrent.name)
    create_dir(base_dir)
    
    var data_offset = 0
    
    for file_info in pm.torrent.files:
      let file_path = join_path(base_dir, join_path(file_info.path))
      let file_dir = parent_dir(file_path)
      
      if not dir_exists(file_dir):
        create_dir(file_dir)
      
      write_file(file_path, all_data[data_offset..<data_offset + file_info.length])
      data_offset += file_info.length
      
      echo "Wrote file: ", file_path
