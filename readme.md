# OpenSearch Routing Partition Size Bug Reproduction

This status badge "passing" means the pinned OpenSearch releases still reproduce the routing-partition bug instead of distributing writes across multiple shards.

[![Test OpenSearch Routing Bug](https://github.com/camerondurham/bug-repro-opensearch-routing/actions/workflows/test-opensearch.yml/badge.svg)](https://github.com/camerondurham/bug-repro-opensearch-routing/actions/workflows/test-opensearch.yml)

This repo contains a test script that monitors whether `routing_partition_size` actually spreads writes across shards in specific OpenSearch releases:

- [OpenSearch #17472](https://github.com/opensearch-project/OpenSearch/issues/17472) - Index setting partition size is ignored if routing num shard setting is not specified

GitHub Actions currently treats `BUG_STATUS=PRESENT` as a passing result. If the behavior changes to `BUG_STATUS=FIXED`, the workflow fails intentionally so this repo can be updated to reflect the fix.
The control case in `test-opensearch-routing.sh` intentionally keeps `number_of_shards=90` and `number_of_routing_shards=90`; lowering both values changed the control result and caused false CI failures.
CI pins explicit OpenSearch releases instead of floating `1`, `2`, and `latest` tags so the badge reflects a stable reproduction rather than upstream tag drift.

Also see:

- OpenSearch current documentation: [Routing: Routing To Specific Shards](https://docs.opensearch.org/docs/latest/field-types/metadata-fields/routing/#routing-to-specific-shards)
- [Elasticsearch #48863](https://github.com/elastic/elasticsearch/issues/48863) - Original Elasticsearch issue describing the same behavior from before the OpenSearch fork

## Bug Description

When creating an index with:
- `routing_partition_size: 2` 
- Required routing
- No `number_of_routing_shards` specified

All documents with the same routing value get assigned to the same shard, instead of being distributed across multiple shards as expected.
In the currently pinned CI releases, the same single-shard behavior is also observed in the control case that sets `number_of_routing_shards`.

## Running the Test

```bash
# run against a specific OpenSearch release tag
./test-opensearch-routing.sh 1.3.20
```

The script will:
- Check if OpenSearch is running locally
- Create two test indices:
  1. With `number_of_routing_shards`
  2. Without `number_of_routing_shards`
- Insert test documents with the same routing value
- Show shard distribution for both cases and assert whether the behavior has changed or not

## Expected vs Actual Behavior

Expected:
- Documents with the same routing value should be distributed across 2 shards (as specified by `routing_partition_size`)

Actual:
- In the pinned CI releases, documents with the same routing value are still routed to a single shard
- The workflow records whether the failure happens only without `number_of_routing_shards` or in both configurations
