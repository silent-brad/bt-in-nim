import std/[strutils, tables, streams]

type
  Bencode_kind* = enum
    bk_int, bk_string, bk_list, bk_dict

  Bencode_value* = ref object
    case kind*: Bencode_kind
    of bk_int: int_val*: int
    of bk_string: str_val*: string
    of bk_list: list_val*: seq[Bencode_value]
    of bk_dict: dict_val*: Ordered_table[string, Bencode_value]

  Bencode_error* = object of Catchable_error

proc new_int*(val: int): Bencode_value =
  Bencode_value(kind: bk_int, int_val: val)

proc new_string*(val: string): Bencode_value =
  Bencode_value(kind: bk_string, str_val: val)

proc new_list*(val: seq[Bencode_value] = @[]): Bencode_value =
  Bencode_value(kind: bk_list, list_val: val)

proc new_dict*(val: Ordered_table[string, Bencode_value] = init_ordered_table[string, Bencode_value]()): Bencode_value =
  Bencode_value(kind: bk_dict, dict_val: val)

# Forward declaration
proc parse_bencode*(data: string, pos: var int): Bencode_value

proc parse_int(data: string, pos: var int): Bencode_value =
  if data[pos] != 'i':
    raise new_exception(Bencode_error, "Expected 'i' at start of integer")
  
  inc pos
  let start = pos
  
  while pos < data.len and data[pos] != 'e':
    if data[pos] notin Digits and data[pos] != '-':
      raise new_exception(Bencode_error, "Invalid character in integer")
    inc pos
  
  if pos >= data.len:
    raise new_exception(Bencode_error, "Unterminated integer")
  
  let int_str = data[start..<pos]
  inc pos  # Skip 'e'
  
  try:
    result = new_int(parse_int(int_str))
  except Value_error:
    raise new_exception(Bencode_error, "Invalid integer: " & int_str)

proc parse_string(data: string, pos: var int): Bencode_value =
  let start = pos
  
  while pos < data.len and data[pos] in Digits:
    inc pos
  
  if pos >= data.len or data[pos] != ':':
    raise new_exception(Bencode_error, "Expected ':' after string length")
  
  let length_str = data[start..<pos]
  inc pos  # Skip ':'
  
  try:
    let length = parse_int(length_str)
    
    if pos + length > data.len:
      raise new_exception(Bencode_error, "String length exceeds data")
    
    let str_val = data[pos..<pos+length]
    pos += length
    
    result = new_string(str_val)
  except Value_error:
    raise new_exception(Bencode_error, "Invalid string length: " & length_str)

proc parse_list(data: string, pos: var int): Bencode_value =
  if data[pos] != 'l':
    raise new_exception(Bencode_error, "Expected 'l' at start of list")
  
  inc pos
  result = new_list()
  
  while pos < data.len and data[pos] != 'e':
    result.list_val.add(data.parse_bencode(pos))
  
  if pos >= data.len:
    raise new_exception(Bencode_error, "Unterminated list")
  
  inc pos  # Skip 'e'

proc parse_dict(data: string, pos: var int): Bencode_value =
  if data[pos] != 'd':
    raise new_exception(Bencode_error, "Expected 'd' at start of dictionary")
  
  inc pos
  result = new_dict()
  
  while pos < data.len and data[pos] != 'e':
    let key = parse_bencode(data, pos)
    if key.kind != bk_string:
      raise new_exception(Bencode_error, "Dictionary key must be string")
    
    let value = parse_bencode(data, pos)
    result.dict_val[key.str_val] = value
  
  if pos >= data.len:
    raise new_exception(Bencode_error, "Unterminated dictionary")
  
  inc pos  # Skip 'e'

proc parse_bencode*(data: string, pos: var int): Bencode_value =
  if pos >= data.len:
    raise new_exception(Bencode_error, "Unexpected end of data")
  
  case data[pos]
  of 'i': result = parse_int(data, pos)
  of 'l': result = parse_list(data, pos)
  of 'd': result = parse_dict(data, pos)
  of '0'..'9': result = parse_string(data, pos)
  else:
    raise new_exception(Bencode_error, "Invalid bencode character: " & $data[pos])

proc parse_bencode*(data: string): Bencode_value =
  var pos = 0
  result = parse_bencode(data, pos)
  if pos < data.len:
    raise new_exception(Bencode_error, "Extra data after bencode")

proc encode_bencode*(value: Bencode_value): string =
  case value.kind
  of bk_int:
    result = "i" & $value.int_val & "e"
  of bk_string:
    result = $value.str_val.len & ":" & value.str_val
  of bk_list:
    result = "l"
    for item in value.list_val:
      result &= encode_bencode(item)
    result &= "e"
  of bk_dict:
    result = "d"
    for key, val in value.dict_val.pairs:
      result &= $key.len & ":" & key
      result &= encode_bencode(val)
    result &= "e"
