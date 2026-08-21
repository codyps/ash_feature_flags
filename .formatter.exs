spark_locals_without_parens = [
  cache_ttl: 1,
  context: 1,
  default: 1,
  description: 1,
  disabled_for_roles: 1,
  flag: 1,
  flag: 2,
  guard_action: 1,
  guard_action: 2,
  guard_attribute: 1,
  guard_attribute: 2,
  enabled_for_roles: 1,
  key: 1,
  on_error: 1,
  policies?: 1,
  prevent_filtering?: 1,
  provider: 1,
  ttl: 1,
  unguarded_actions: 1,
  variant: 1
]

[
  import_deps: [:ash, :spark],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}"],
  locals_without_parens: spark_locals_without_parens,
  export: [locals_without_parens: spark_locals_without_parens]
]
