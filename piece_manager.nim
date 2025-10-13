import std/[tables, sets, sha1, strutils, os, streams]
import torrent, peer_wire

type
  PieceManager* = ref object
    torrent*: TorrentFile
    pieces*: seq[PieceState]
    completed_pieces*: HashSet[int]
    pending_blocks*: Table[int, seq[BlockRequest]]
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

proc new_piece_manager*(torrent: TorrentFile): PieceManager =
  result = PieceManager(
    torrent: torrent,
    pieces: @[],
    completed_pieces: initHashSet[int](),
    pending_blocks: initTable[int, seq[BlockRequest]](),
    downloaded_data: initTable[int, string]()
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

proc sha1_hash(data: string): string =
  let hash = secureHash(data)
  result = $hash

proc get_next_block*(pm: PieceManager, peer_pieces: seq[bool]): BlockRequest =
  # Find a piece that the peer has and we need
  for piece_idx in 0..<pm.pieces.len:
    if piece_idx >= peer_pieces.len or not peer_pieces[piece_idx]:
      continue
    
    if piece_idx in pm.completed_pieces:
      continue
    
    let piece = pm.pieces[piece_idx]
    
    # Find an undownloaded block in this piece
    for blk in piece.blocks:
      if not blk.downloaded:
        return BlockRequest(
          piece_index: piece_idx,
          begin: blk.begin,
          length: blk.length,
          peer: ""
        )
  
  # No blocks found
  raise newException(CatchableError, "No blocks available")

proc add_block*(pm: PieceManager, piece_index: int, begin: int, data: string): bool =
  if piece_index < 0 or piece_index >= pm.pieces.len:
    return false
  
  var piece = addr pm.pieces[piece_index]
  
  # Find the corresponding block
  for i in 0..<piece.blocks.len:
    if piece.blocks[i].begin == begin:
      if piece.blocks[i].downloaded:
        return false  # Already have this block
      
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
        let actual_hash = sha1_hash(piece_data)
        
        if actual_hash == expected_hash:
          piece.verified = true
          piece.downloaded = true
          pm.completed_pieces.incl(piece_index)
          pm.downloaded_data[piece_index] = piece_data
          
          echo "Piece ", piece_index, " completed and verified"
          return true
        else:
          echo "Piece ", piece_index, " failed verification"
          # Reset all blocks in this piece
          for j in 0..<piece.blocks.len:
            piece.blocks[j].downloaded = false
            piece.blocks[j].data = ""
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
  
  if pm.torrent.files.len == 0:
    # Single file torrent
    let filename = joinPath(output_dir, pm.torrent.name)
    let file_stream = newFileStream(filename, fmWrite)
    defer: file_stream.close()
    
    for i in 0..<pm.pieces.len:
      let piece_data = pm.get_piece_data(i)
      file_stream.write(piece_data)
    
    echo "Wrote single file: ", filename
  else:
    # Multi-file torrent
    let base_dir = joinPath(output_dir, pm.torrent.name)
    createDir(base_dir)
    
    var data_offset = 0
    
    for file_info in pm.torrent.files:
      let file_path = joinPath(base_dir, joinPath(file_info.path))
      let file_dir = parentDir(file_path)
      
      if not dirExists(file_dir):
        createDir(file_dir)
      
      let file_stream = newFileStream(file_path, fmWrite)
      defer: file_stream.close()
      
      var remaining = file_info.length
      
      while remaining > 0:
        let piece_index = data_offset div pm.torrent.piece_length
        let piece_offset = data_offset mod pm.torrent.piece_length
        let piece_data = pm.get_piece_data(piece_index)
        
        let to_read = min(remaining, piece_data.len - piece_offset)
        let chunk = piece_data[piece_offset..<piece_offset + to_read]
        
        file_stream.write(chunk)
        data_offset += to_read
        remaining -= to_read
      
      echo "Wrote file: ", file_path
