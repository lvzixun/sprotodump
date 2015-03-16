# sproto_dump
parse sproto file `.sproto` to binary file `.spb` or c# code `.cs`.

usage is as follows:
```
  usage: lua sprotodump.lua [[<out_option> <out>] ...] <option> <sproto_file ...>

  out_option:
    -d               dump to speciffic dircetory
    -o               dump to speciffic file
    -p               set package name(only cSharp code use)

  option: 
    -cs              dump to cSharp code file
    -spb             dump to binary spb  file
```
