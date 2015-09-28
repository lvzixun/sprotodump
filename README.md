# sproto_dump
parse sproto file `.sproto` to binary file `.spb` or c# code `.cs`.

usage is as follows:
```
usage: lua sprotodump.lua <option> <sproto_file1 sproto_file2 ...> [[<out_option> <outfile>] ...] [namespace_option]

    option: 
        -cs              dump to cSharp code file
        -spb             dump to binary spb  file

    out_option:
        -d <dircetory>               dump to speciffic dircetory
        -o <file>                    dump to speciffic file
        -p <package name>            set package name(only cSharp code use)

    namespace_option:
        -namespace       add namespace to type and protocol
```
