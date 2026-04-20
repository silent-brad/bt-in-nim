import std/[strutils, tables, hashes, streams, sha1]
import bencode

type
  TorrentFile* = object
    announce*: string
    info_hash*: string
    piece_length*: int
    pieces*: string
    length*: int
    name*: string
    files*: seq[FileInfo]
  
  FileInfo* = object
    length*: int
    path*: seq[string]

  TorrentError* = object of CatchableError

proc sha1_hash(data: string): string =
  let hash = secure_hash(data)
  result = $hash

proc parse_torrent*(filename: string): TorrentFile =
  let content = read_file(filename)
  let decoded = parse_bencode(content)
  
  if decoded.kind != bk_dict:
    raise new_exception(TorrentError, "Invalid torrent file: root must be dictionary")
  
  let root = decoded.dict_val
  
  if "announce" notin root:
    raise new_exception(TorrentError, "Missing announce URL")
  
  if root["announce"].kind != bk_string:
    raise new_exception(TorrentError, "Invalid announce URL")
  
  result.announce = root["announce"].str_val
  
  if "info" notin root:
    raise new_exception(TorrentError, "Missing info dictionary")
  
  if root["info"].kind != bk_dict:
    raise new_exception(TorrentError, "Invalid info dictionary")
  
  let info = root["info"].dict_val
  
  # Calculate info hash
  let info_encoded = encode_bencode(root["info"])
  result.info_hash = sha1_hash(info_encoded)
  
  # Parse info dictionary
  if "piece length" notin info:
    raise new_exception(TorrentError, "Missing piece length")
  
  if info["piece length"].kind != bk_int:
    raise new_exception(TorrentError, "Invalid piece length")
  
  result.piece_length = info["piece length"].int_val
  
  if "pieces" notin info:
    raise new_exception(TorrentError, "Missing pieces")
  
  if info["pieces"].kind != bk_string:
    raise new_exception(TorrentError, "Invalid pieces")
  
  result.pieces = info["pieces"].str_val
  
  if "name" notin info:
    raise new_exception(TorrentError, "Missing name")
  
  if info["name"].kind != bk_string:
    raise new_exception(TorrentError, "Invalid name")
  
  result.name = info["name"].str_val
  
  # Handle single file vs multi-file torrents
  if "length" in info:
    # Single file torrent
    if info["length"].kind != bk_int:
      raise new_exception(TorrentError, "Invalid length")
    
    result.length = info["length"].int_val
    result.files = @[]
  else:
    # Multi-file torrent
    if "files" notin info:
      raise new_exception(TorrentError, "Missing files list in multi-file torrent")
    
    if info["files"].kind != bk_list:
      raise new_exception(TorrentError, "Invalid files list")
    
    result.length = 0
    result.files = @[]
    
    for file_item in info["files"].list_val:
      if file_item.kind != bk_dict:
        raise new_exception(TorrentError, "Invalid file entry")
      
      let file_dict = file_item.dict_val
      
      if "length" notin file_dict or file_dict["length"].kind != bk_int:
        raise new_exception(TorrentError, "Invalid file length")
      
      if "path" notin file_dict or file_dict["path"].kind != bk_list:
        raise new_exception(TorrentError, "Invalid file path")
      
      var FileInfo = FileInfo()
      FileInfo.length = file_dict["length"].int_val
      result.length += FileInfo.length
      
      for path_component in file_dict["path"].list_val:
        if path_component.kind != bk_string:
          raise new_exception(TorrentError, "Invalid path component")
        FileInfo.path.add(path_component.str_val)
      
      result.files.add(FileInfo)

proc piece_count*(torrent: TorrentFile): int =
  result = (torrent.length + torrent.piece_length - 1) div torrent.piece_length

proc piece_hash*(torrent: TorrentFile, piece_index: int): string =
  let hash_start = piece_index * 20
  let hash_end = hash_start + 20
  
  if hash_end > torrent.pieces.len:
    raise new_exception(TorrentError, "Invalid piece index")
  
  result = torrent.pieces[hash_start..<hash_end]

proc piece_size*(torrent: TorrentFile, piece_index: int): int =
  let last_piece = torrent.piece_count() - 1
  
  if piece_index < 0 or piece_index > last_piece:
    raise new_exception(TorrentError, "Invalid piece index")
  
  if piece_index == last_piece:
    result = torrent.length mod torrent.piece_length
    if result == 0:
      result = torrent.piece_length
  else:
    result = torrent.piece_length
