# Changelog

## v0.1.0

Initial release.

- `feature_flags` DSL section for Ash resources: `flag`, `guard_action`,
  `guard_attribute`
- Guards compile into `Ash.Policy.Authorizer` policies and field policies, so
  they compose with `ash_authentication` roles and rules as AND rather than
  replacing them
- `guard_attribute` also refuses reads that filter on a hidden field, closing
  the bisection leak that field policies alone leave open
  (`prevent_filtering? false` to opt out)
- Providers: Flipt, OpenFeature/OFREP, LaunchDarkly, an Ash-resource-backed
  database table (`AshFeatureFlags.FlagStore`), and Static for tests
- `flag_enabled/1`, `flag_disabled/1` and `flag_variant/2` policy checks usable
  on any resource, with or without the extension
- Per-actor ETS caching with TTL, telemetry, and configurable failure behaviour
- Compile-time verification of flag, action, field and provider references
- `error_ttl` (default `0`) to optionally cache the fallback value after a
  provider failure, so an outage stops costing a timeout per guard per request
