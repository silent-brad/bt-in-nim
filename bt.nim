import std/[os, strutils]
import client

proc print_usage() =
  echo "Usage: bt <torrent-file>"
  echo "  torrent-file: Path to the .torrent file to download"

proc main() =
  let args = command_line_params()

  if args.len != 1:
    print_usage()
    quit(1)
  
  let torrent_file = args[0]

  if not file_exists(torrent_file):
    echo "Error: Torrent file not found: ", torrent_file
    quit(1)
  
  echo "BitTorrent Client in Nim"
  echo "========================"
  echo "Torrent file: ", torrent_file
  echo ""
  
  try:
    let client = new_torrent_client(torrent_file)
    client.download()
  except Exception as e:
    echo "Fatal error: ", e.msg
    quit(1)

when is_main_module:
  main()
