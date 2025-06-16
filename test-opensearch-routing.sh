#!/bin/bash

set -e

OPENSEARCH_URL="http://localhost:9200"
OPENSEARCH_VERSION=${1:-"1"}  # Default to latest 1.x

echo "Testing OpenSearch version: ${OPENSEARCH_VERSION}"

# Function to retry commands
retry_command() {
    local cmd="$1"
    local max_attempts=3
    local attempt=1
    local exit_code=0

    while [[ $attempt -le $max_attempts ]]; do
        echo "Attempt $attempt of $max_attempts: Running Docker command..."
        
        # Execute the command
        eval "$cmd"
        exit_code=$?
        
        if [[ $exit_code -eq 0 ]]; then
            return 0
        else
            echo "Attempt $attempt failed with exit code $exit_code. Retrying in 5 seconds..."
            sleep 5
            ((attempt++))
        fi
    done
    
    echo "All $max_attempts attempts failed!"
    return $exit_code
}

check_opensearch() {
    if ! curl -s "${OPENSEARCH_URL}/_cluster/health" > /dev/null; then
        echo "Starting OpenSearch ${OPENSEARCH_VERSION}..."
        
        if [[ "${OPENSEARCH_VERSION}" == "2."* || "${OPENSEARCH_VERSION}" == "latest" ]]; then
            # For OpenSearch after 2.12
            # https://gallery.ecr.aws/opensearchproject/opensearch
            retry_command "docker run -d -p 9200:9200 -p 9600:9600 \
                -e \"discovery.type=single-node\" \
                -e \"DISABLE_SECURITY_PLUGIN=true\" \
                -e \"DISABLE_INSTALL_DEMO_CONFIG=true\" \
                -e \"OPENSEARCH_INITIAL_ADMIN_PASSWORD=[REDACTED:PASSWORD]\" \
                public.ecr.aws/opensearchproject/opensearch:${OPENSEARCH_VERSION}"
        else
            # For OpenSearch 1.x versions
            retry_command "docker run -d -p 9200:9200 \
                -e \"discovery.type=single-node\" \
                -e \"DISABLE_SECURITY_PLUGIN=true\" \
                -e \"DISABLE_INSTALL_DEMO_CONFIG=true\" \
                public.ecr.aws/opensearchproject/opensearch:${OPENSEARCH_VERSION}"
        fi

        echo "Waiting for OpenSearch to start..."
        until curl -s "${OPENSEARCH_URL}/_cluster/health" > /dev/null; do
            echo -n "."
            sleep 1
        done
        echo -e "\nOpenSearch is ready!"
    else
        echo "OpenSearch is already running"
        version_info=$(curl -s "${OPENSEARCH_URL}" | jq -r '.version | "OpenSearch \(.number) (\(.distribution))"')
        echo "Version info: ${version_info}"
    fi
}

create_index() {
    local index_name=$1
    local with_routing_shards=$2
    local settings

    curl -s -XDELETE "${OPENSEARCH_URL}/${index_name}" > /dev/null

    if [ "$with_routing_shards" = true ]; then
        settings='{
            "settings": {
                "index": {
                    "number_of_shards": "90",
                    "number_of_routing_shards": "90",
                    "number_of_replicas": "0",
                    "routing_partition_size": "2"
                }
            },
            "mappings": {
                "_routing": {
                    "required": true
                }
            }
        }'
    else
        settings='{
            "settings": {
                "index": {
                    "number_of_shards": "90",
                    "number_of_replicas": "0",
                    "routing_partition_size": "2"
                }
            },
            "mappings": {
                "_routing": {
                    "required": true
                }
            }
        }'
    fi

    echo "Creating index ${index_name}"
    curl -s -XPUT "${OPENSEARCH_URL}/${index_name}" \
        -H "Content-Type: application/json" \
        -d "$settings" > /dev/null
}

insert_test_documents() {
    local index_name=$1
    local routing_value="42"
    local count=20

    echo "Inserting ${count} test documents with routing=${routing_value}"
    for i in $(seq 1 $count); do
        curl -s -XPUT "${OPENSEARCH_URL}/${index_name}/_doc/${i}?routing=${routing_value}" \
            -H "Content-Type: application/json" \
            -d "{\"client_id\":\"${routing_value}\"}" > /dev/null
    done
}

check_shards_distribution() {
    local index_name=$1
    local routing_value="42"
    local expected_shards=2

    echo "Checking shard distribution for routing value ${routing_value}:"
    echo "Number of shards and their details:"
    
    local response=$(curl -s -XGET "${OPENSEARCH_URL}/${index_name}/_search_shards?routing=${routing_value}")
    
    echo "$response" | jq -c '.shards[]'
    
    local shard_count=$(echo "$response" | jq '.shards | length')
    
    echo -e "\nResults for ${index_name}:"
    echo "Expected number of shards: ${expected_shards}"
    echo "Actual number of shards: ${shard_count}"
    
    if [ "$shard_count" -eq "$expected_shards" ]; then
        echo "✅ PASS: Documents are correctly distributed across ${expected_shards} shards"
    else
        echo "❌ FAIL: Documents are routed to ${shard_count} shard(s) instead of ${expected_shards}"
    fi
}

demonstrate_routing_bug() {
    echo "=== Testing with number_of_routing_shards set ==="
    create_index "test_with_routing" true
    insert_test_documents "test_with_routing"
    check_shards_distribution "test_with_routing"
    echo

    echo "=== Testing without number_of_routing_shards set ==="
    create_index "test_without_routing" false
    insert_test_documents "test_without_routing"
    check_shards_distribution "test_without_routing"
    
    echo -e "\n=== Test Summary ==="
    echo "The bug is present if:"
    echo "1. Test with number_of_routing_shards passes (shows 2 shards)"
    echo "2. Test without number_of_routing_shards fails (shows 1 shard)"
    echo "This demonstrates that routing_partition_size is ignored when number_of_routing_shards is not set"
}

if ! command -v docker &> /dev/null; then
    echo "Docker is not installed. Please install Docker first."
    exit 1
fi

if ! command -v jq &> /dev/null; then
    echo "jq is not installed. Please install jq first."
    exit 1
fi

check_opensearch
demonstrate_routing_bug

container_id=$(docker ps -q --filter "publish=9200")
if [ ! -z "$container_id" ]; then
    echo "Stopping OpenSearch container..."
    docker stop "$container_id"
fi
