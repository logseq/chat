bool shouldPollGraphCatalog({
  required bool authenticated,
  required bool hasOpenGraph,
  required bool foreground,
}) =>
    authenticated && !hasOpenGraph && foreground;
