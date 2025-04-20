# OpenSearch Routing Partition Size Bug Reproduction

[![Test OpenSearch Routing Bug](https://github.com/camerondurham/bug-repro-opensearch-routing/actions/workflows/test-opensearch.yml/badge.svg)](https://github.com/camerondurham/bug-repro-opensearch-routing/actions/workflows/test-opensearch.yml)

This is a test script to try reproducing some unexpected behavior with index routing when you don't set `number_of_routing_shards` AND `routing_partition_size` on index creation, causing all documents to be routed to a single shard instead of being distributed.

See OpenSearch current documentation: [Routing: Routing To Specific Shards](https://docs.opensearch.org/docs/latest/field-types/metadata-fields/routing/#routing-to-specific-shards)

## Related Issues

- [OpenSearch #17472](https://github.com/opensearch-project/OpenSearch/issues/17472) - Index setting partition size is ignored if routing num shard setting is not specified
- [Elasticsearch #48863](https://github.com/elastic/elasticsearch/issues/48863) - Original Elasticsearch issue describing the same behavior

## Bug Description

When creating an index with:
- `routing_partition_size: 2` 
- Required routing
- No `number_of_routing_shards` specified

All documents with the same routing value get assigned to the same shard, instead of being distributed across multiple shards as expected.

## Running the Test

```bash
# run with opensearch 1, 2, 3 release (from tags: https://gallery.ecr.aws/opensearchproject/opensearch)
# have only tested so far with 1 or 2
./opensearch_routing_bug.sh 1
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
- With `number_of_routing_shards`: Documents are correctly distributed
- Without `number_of_routing_shards`: All documents go to the same shard

