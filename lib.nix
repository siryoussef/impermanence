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
      # Use a string directly to avoid coercion issues/recursion if possible
      pathStr = toString (if dirPath != null then dirPath else filePath);
      
      strippedPath =
        if removePrefixDirectory && home != null then
          lib.removePrefix (toString home) pathStr
        else if removePrefixDirectory then
          let
            # Avoid splitting multiple times
            parts = filter (s: s != "") (lib.splitString "/" pathStr);
          in
          if length parts > 1 then
            "/" + (concatStringsSep "/" (lib.drop 1 parts))
          else
            "/"
        else
          pathStr;
    in
    concatPaths [ (toString persistentStoragePath) strippedPath ];

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
