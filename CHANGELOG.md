# Legion::Cache

## v1.2.1 - 2026-03-16

### Fixed
- Set dalli `value_max_bytes` to 8MB by default — dalli enforces a 1MB client-side limit that prevented large cache values from being stored even when memcached server allows larger items

## v1.2.0
Moving from BitBucket to GitHub. All git history is reset from this point on
