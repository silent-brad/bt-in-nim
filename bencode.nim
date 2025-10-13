import std/[strutils, tables, streams]

type
  BencodeValue* = ref object
    case kind*: BencodeKind
    of bkInt: int_val*: int
    of bkString: str_val*: string
    of bkList: list_val*: seq[BencodeValue]
    of bkDict: dict_val*: OrderedTable[string, BencodeValue]

  BencodeKind* = enum
    bkInt, bkString, bkList, bkDict

  BencodeError* = object of CatchableError

proc new_int*(val: int): BencodeValue =
  BencodeValue(kind: bkInt, int_val: val)

proc new_string*(val: string): BencodeValue =
  BencodeValue(kind: bkString, str_val: val)

proc new_list*(val: seq[BencodeValue] = @[]): BencodeValue =
  BencodeValue(kind: bkList, list_val: val)

proc new_dict*(val: OrderedTable[string, BencodeValue] = initOrderedTable[string, BencodeValue]()): BencodeValue =
  BencodeValue(kind: bkDict, dict_val: val)

proc parse_int(data: string, pos: var int): BencodeValue =
  if data[pos] != 'i':
    raise newException(BencodeError, "Expected 'i' at start of integer")
  
  inc pos
  let start = pos
  
  while pos < data.len and data[pos] != 'e':
    if data[pos] notin Digits and data[pos] != '-':
      raise newException(BencodeError, "Invalid character in integer")
    inc pos
  
  if pos >= data.len:
    raise newException(BencodeError, "Unterminated integer")
  
  let int_str = data[start..<pos]
  inc pos  # Skip 'e'
  
  try:
    result = new_int(parseInt(int_str))
  except ValueError:
    raise newException(BencodeError, "Invalid integer: " & int_str)

proc parse_string(data: string, pos: var int): BencodeValue =
  let start = pos
  
  while pos < data.len and data[pos] in Digits:
    inc pos
  
  if pos >= data.len or data[pos] != ':':
    raise newException(BencodeError, "Expected ':' after string length")
  
  let length_str = data[start..<pos]
  inc pos  # Skip ':'
  
  try:
    let length = parseInt(length_str)
    
    if pos + length > data.len:
      raise newException(BencodeError, "String length exceeds data")
    
    let str_val = data[pos..<pos+length]
    pos += length
    
    result = new_string(str_val)
  except ValueError:
    raise newException(BencodeError, "Invalid string length: " & length_str)

proc parse_list(data: string, pos: var int): BencodeValue =
  if data[pos] != 'l':
    raise newException(BencodeError, "Expected 'l' at start of list")
  
  inc pos
  result = new_list()
  
  while pos < data.len and data[pos] != 'e':
    result.list_val.add(parse_bencode(data, pos))
  
  if pos >= data.len:
    raise newException(BencodeError, "Unterminated list")
  
  inc pos  # Skip 'e'

proc parse_dict(data: string, pos: var int): BencodeValue =
  if data[pos] != 'd':
    raise newException(BencodeError, "Expected 'd' at start of dictionary")
  
  inc pos
  result = new_dict()
  
  while pos < data.len and data[pos] != 'e':
    let key = parse_bencode(data, pos)
    if key.kind != bkString:
      raise newException(BencodeError, "Dictionary key must be string")
    
    let value = parse_bencode(data, pos)
    result.dict_val[key.str_val] = value
  
  if pos >= data.len:
    raise newException(BencodeError, "Unterminated dictionary")
  
  inc pos  # Skip 'e'

proc parse_bencode*(data: string, pos: var int): BencodeValue =
  if pos >= data.len:
    raise newException(BencodeError, "Unexpected end of data")
  
  case data[pos]
  of 'i': result = parse_int(data, pos)
  of 'l': result = parse_list(data, pos)
  of 'd': result = parse_dict(data, pos)
  of '0'..'9': result = parse_string(data, pos)
  else:
    raise newException(BencodeError, "Invalid bencode character: " & $data[pos])

proc parse_bencode*(data: string): BencodeValue =
  var pos = 0
  result = parse_bencode(data, pos)
  if pos < data.len:
    raise newException(BencodeError, "Extra data after bencode")

proc encode_bencode*(value: BencodeValue): string =
  case value.kind
  of bkInt:
    result = "i" & $value.int_val & "e"
  of bkString:
    result = $value.str_val.len & ":" & value.str_val
  of bkList:
    result = "l"
    for item in value.list_val:
      result &= encode_bencode(item)
    result &= "e"
  of bkDict:
    result = "d"
    for key, val in value.dict_val.pairs:
      result &= $key.len & ":" & key
      result &= encode_bencode(val)
    result &= "e"
