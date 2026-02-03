# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Break Versioning](https://www.taoensso.com/break-versioning).

## [Unreleased]

### Added

### Changed

### Deprecated

### Removed

### Fixed

### Security

[Unreleased]: https://github.com/hanami/hanami-webconsole/compare/v2.3.1...main

## [2.3.1] - 2025-12-18

### Changed

- Bypass binding_of_caller's Ruby version check and load its functionality directly. This ensures it continues to work when running under Ruby 4.0. (@timriley in #12)

[2.3.1]: https://github.com/hanami/hanami-webconsole/compare/v2.3.0...v2.3.1

## [2.3.0] - 2025-11-12

[2.3.0]: https://github.com/hanami/hanami-webconsole/compare/v2.3.0.beta2...v2.3.0

## [2.3.0.beta2] - 2025-10-17

### Changed

- Drop support for Ruby 3.1.

[2.3.0.beta2]: https://github.com/hanami/hanami-webconsole/compare/v2.3.0.beta1...v2.3.0.beta2

## [2.3.0.beta1] - 2025-10-03

[2.3.0.beta1]: https://github.com/hanami/hanami-webconsole/compare/v2.2.0...v2.3.0.beta1

## [2.2.0] - 2024-11-05

[2.2.0]: https://github.com/hanami/hanami-webconsole/compare/v2.2.0.rc1...v2.2.0

## [2.2.0.rc1] - 2024-10-29

[2.2.0.rc1]: https://github.com/hanami/hanami-webconsole/compare/v2.2.0.beta2...v2.2.0.rc1

## [2.2.0.beta2] - 2024-09-25

[2.2.0.beta2]: https://github.com/hanami/hanami-webconsole/compare/v2.2.0.beta1...v2.2.0.beta2

## [2.2.0.beta1] - 2024-07-16

### Changed

- Drop support for Ruby 3.0.

[2.2.0.beta1]: https://github.com/hanami/hanami-webconsole/compare/v2.1.0...v2.2.0.beta1

## [2.1.0] - 2024-02-27

[2.1.0]: https://github.com/hanami/hanami-webconsole/compare/v2.1.0.rc3...v2.1.0

## [2.1.0.rc3] - 2024-02-16

[2.1.0.rc3]: https://github.com/hanami/hanami-webconsole/compare/v2.1.0.rc2...v2.1.0.rc3

## [2.1.0.rc2] - 2023-11-08

[2.1.0.rc2]: https://github.com/hanami/hanami-webconsole/compare/v2.1.0.rc1...v2.1.0.rc2

## [2.1.0.rc1] - 2023-11-02

[2.1.0.rc1]: https://github.com/hanami/hanami-webconsole/compare/v2.1.0.beta2...v2.1.0.rc1

## [2.1.0.beta2] - 2023-10-04

### Fixed

- Set correct error codes for Hanami app exceptions. (@timriley)

[2.1.0.beta2]: https://github.com/hanami/hanami-webconsole/compare/v2.1.0.beta1...v2.1.0.beta2

## [2.1.0.beta1] - 2023-06-29

### Added

- Introduce `Hanami::Webconsole::Middleware`, a Rack middleware automatically used in the Hanami app when hanami-webconsole is bundled. (@timriley in #6)

### Changed

- Remove the Hanami v1 plugin. (@timriley in #6)

[2.1.0.beta1]: https://github.com/hanami/hanami-webconsole/compare/v0.2.0...v2.1.0.beta1

## [0.2.0] - 2019-01-18

### Added

- Official support for Ruby 2.6.0. (@jodosha)
- Support for `bundler` 2.0+. (@jodosha)

[0.2.0]: https://github.com/hanami/hanami-webconsole/compare/v0.1.0...v0.2.0

## [0.1.0] - 2018-04-11

[0.1.0]: https://github.com/hanami/hanami-webconsole/compare/v0.1.0.rc2...v0.1.0

## [0.1.0.rc2] - 2018-04-06

[0.1.0.rc2]: https://github.com/hanami/hanami-webconsole/compare/v0.1.0.rc1...v0.1.0.rc2

## [0.1.0.rc1] - 2018-03-30

[0.1.0.rc1]: https://github.com/hanami/hanami-webconsole/compare/v0.1.0.beta2...v0.1.0.rc1

## [0.1.0.beta2] - 2018-03-23

[0.1.0.beta2]: https://github.com/hanami/hanami-webconsole/compare/v0.1.0.beta1...v0.1.0.beta2

## [0.1.0.beta1] - 2018-02-28

### Added

- Package as Hanami plugin. (@jodosha & Anton Davydov)

[0.1.0.beta1]: https://github.com/hanami/hanami-webconsole/releases/tag/v0.1.0.beta1
