{ lib }:
let
  inherit (lib)
    filter
    concatMap
    concatStringsSep
    hasPrefix
    head
    optionalString
    foldl'
    elem
    take
    length
    last
    ;

  # ["/home/user/" "/.screenrc"] -> ["home" "user" ".screenrc"]
  splitPath = paths:
    (filter
      (s: builtins.typeOf s == "string" && s != "")
      (concatMap (builtins.split "/") paths)
    );

  # ["home" "user" ".screenrc"] -> "home/user/.screenrc"
  dirListToPath = dirList: (concatStringsSep "/" dirList);

  # ["/home/user/" "/.screenrc"] -> "/home/user/.screenrc"
  concatPaths = paths:
    let
      prefix = optionalString (hasPrefix "/" (head paths)) "/";
      path = dirListToPath (splitPath paths);
    in
    prefix + path;

  parentsOf = path:
    let
      prefix = optionalString (hasPrefix "/" path) "/";
      split = splitPath [ path ];
      parents = take ((length split) - 1) split;
    in
    foldl'
      (state: item:
        state ++ [
          (concatPaths [
            (if state != [ ] then last state else prefix)
            item
          ])
        ])
      [ ]
      parents;

  duplicates = list:
    let
      result =
        foldl'
          (state: item:
            if elem item state.items then
              {
                items = state.items ++ [ item ];
                duplicates = state.duplicates ++ [ item ];
              }
            else
              state // {
                items = state.items ++ [ item ];
              })
          { items = [ ]; duplicates = [ ]; }
          list;
    in
    result.duplicates;

  getPersistentPath = { persistentStoragePath, dirPath ? null, filePath ? null, removePrefixDirectory ? false, home ? null, ... }:
    let
      path = if dirPath != null then dirPath else filePath;
      strippedPath =
        if removePrefixDirectory && home != null then
          lib.removePrefix home path
        else if removePrefixDirectory then
          let
            parts = filter (s: s != "") (lib.splitString "/" path);
          in
          "/" + (concatStringsSep "/" (lib.drop 1 (filter (s: s != "") (lib.splitString "/" path))))
        else
          path;
    in
    concatPaths [ persistentStoragePath strippedPath ];

in
{
  inherit
    splitPath
    dirListToPath
    concatPaths
    parentsOf
    duplicates
    getPersistentPath
    ;
}
