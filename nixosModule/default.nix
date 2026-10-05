{
  config,
  lib,
  pkgs,
  ...
}:

{
  imports = [
    ./victoriaStack
    ./victoriaCollector
  ];
}
