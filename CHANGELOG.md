# Hanami::Webconsole

Hanami development web console.

## [Unreleased]

### Added

### Changed

### Deprecated

### Removed

### Fixed

### Security

[Unreleased]: https://github.com/hanami/hanami-webconsole/compare/v2.3.1...main

## [v2.3.1] - 2025-12-18

### Changed

- Bypass binding_of_caller's Ruby version check and load its functionality directly. This ensures it continues to work when running under Ruby 4.0. (@timriley in #12)

[v2.3.1]: https://github.com/hanami/hanami-webconsole/compare/v2.3.0...v2.3.1

## v2.3.0 - 2025-11-12

## v2.3.0.beta2 - 2025-10-17

### Changed

- Drop support for Ruby 3.1

## v2.3.0.beta1 - 2025-10-03

## v2.2.0 - 2024-11-05

## v2.2.0.rc1 - 2024-10-29

## v2.2.0.beta2 - 2024-09-25

## v2.2.0.beta1 - 2024-07-16

### Changed

- Drop support for Ruby 3.0

## v2.1.0 - 2024-02-27

## v2.1.0.rc3 - 2024-02-16

## v2.1.0.rc2 - 2023-11-08

## v2.1.0.rc1 - 2023-11-02

## v2.1.0.beta2 - 2023-10-04

### Fixed

- [Tim Riley] Set correct error codes for Hanami app exceptions

## v2.1.0.beta1 - 2023-06-29

### Added

- [Tim Riley] Introduce `Hanami::Webconsole::Middleware`, a Rack middleware automatically used in
  the Hanami app when hanami-webconsole is bundled (#6)

### Changed

- [Tim Riley] Remove the Hanami v1 plugin (#6)

## v0.2.0 - 2019-01-18

### Added

- [Luca Guidi] Official support for Ruby 2.6.0
- [Luca Guidi] Support for `bundler` 2.0+

## v0.1.0 - 2018-04-11

## v0.1.0.rc2 - 2018-04-06

## v0.1.0.rc1 - 2018-03-30

## v0.1.0.beta2 - 2018-03-23

## v0.1.0.beta1 - 2018-02-28

### Added

- [Luca Guidi & Anton Davydov] Package as Hanami plugin
