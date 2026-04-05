#!/bin/bash

set -euo pipefail

OPENSEARCH_URL="http://localhost:9200"
OPENSEARCH_VERSION=${1:-"1"}  # Default to latest 1.x
# Keep the control case at the previously passing 90/90 shard configuration.
NUMBER_OF_SHARDS=${NUMBER_OF_SHARDS:-"90"}
NUMBER_OF_ROUTING_SHARDS=${NUMBER_OF_ROUTING_SHARDS:-"90"}
TEST_RESULTS_FILE=${TEST_RESULTS_FILE:-"test-results.txt"}
OPENSEARCH_CONTAINER_ID=""
WITH_ROUTING_RESULT="UNKNOWN"
WITHOUT_ROUTING_RESULT="UNKNOWN"
BUG_STATUS="UNKNOWN"

echo "Testing OpenSearch version: ${OPENSEARCH_VERSION}"

# Function to retry commands with exponential backoff
retry_command() {
    local cmd="$1"
    local max_attempts=3
    local attempt=1
    local exit_code=0
    local wait_time=10  # Starting with a longer wait time

    while [[ $attempt -le $max_attempts ]]; do
        echo "Attempt $attempt of $max_attempts: Running command..."
        
        # Execute the command
        eval "$cmd"
        exit_code=$?
        
        if [[ $exit_code -eq 0 ]]; then
            return 0
        else
            echo "Attempt $attempt failed with exit code $exit_code."
            if [[ $attempt -lt $max_attempts ]]; then
                echo "Waiting ${wait_time} seconds before retry..."
                sleep $wait_time
                # Exponential backoff: double the wait time for next attempt
                wait_time=$((wait_time * 2))
                ((attempt++))
            else
                echo "All $max_attempts attempts failed!"
                return $exit_code
            fi
        fi
    done
}

# Function to safely pull Docker image
pull_docker_image() {
    local image_name="$1"
    echo "Pulling Docker image: $image_name"
    
    # Check if image already exists locally
    if docker image inspect "$image_name" &>/dev/null; then
        echo "Image already exists locally, skipping pull."
        return 0
    fi
    
    # Try to pull the image
    retry_command "docker pull $image_name"
    return $?
}

check_opensearch() {
    if ! curl -s "${OPENSEARCH_URL}/_cluster/health" > /dev/null 2>&1; then
        echo "Starting OpenSearch ${OPENSEARCH_VERSION}..."
        
        local image_name="public.ecr.aws/opensearchproject/opensearch:${OPENSEARCH_VERSION}"
        
        # First pull the Docker image
        if ! pull_docker_image "$image_name"; then
            echo "Failed to pull Docker image after multiple attempts. Trying to continue with existing image..."
        fi
        
        # Then run the container
        local container_id=""
        if [[ "${OPENSEARCH_VERSION}" == "2."* || "${OPENSEARCH_VERSION}" == "latest" ]]; then
            # For OpenSearch after 2.12
            container_id=$(docker run -d -p 9200:9200 -p 9600:9600 \
                -e "discovery.type=single-node" \
                -e "DISABLE_SECURITY_PLUGIN=true" \
                -e "DISABLE_INSTALL_DEMO_CONFIG=true" \
                -e "OPENSEARCH_INITIAL_ADMIN_PASSWORD=admin" \
                "$image_name")
        else
            # For OpenSearch 1.x versions
            container_id=$(docker run -d -p 9200:9200 \
                -e "discovery.type=single-node" \
                -e "DISABLE_SECURITY_PLUGIN=true" \
                -e "DISABLE_INSTALL_DEMO_CONFIG=true" \
                "$image_name")
        fi

        if [ -z "$container_id" ]; then
            echo "Failed to start OpenSearch container!"
            return 1
        fi
        
        echo "Container started with ID: $container_id"
        
        # Wait a bit before checking logs to give the container time to output initial logs
        sleep 5
        
        echo "Waiting for OpenSearch to start..."
        local max_wait=120  # Increased maximum wait time in seconds
        local elapsed=0
        local success=false
        
        while [ $elapsed -lt $max_wait ]; do
            if curl -s "${OPENSEARCH_URL}/_cluster/health" > /dev/null 2>&1; then
                success=true
                break
            fi
            
            # Every 15 seconds, check container status
            if [ $((elapsed % 15)) -eq 0 ] && [ $elapsed -gt 0 ]; then
                echo -e "\nChecking container status at ${elapsed}s:"
                if ! docker ps | grep -q "$container_id"; then
                    echo "Container is no longer running! Here are the logs:"
                    docker logs "$container_id"
                    return 1
                fi
            fi
            
            echo -n "."
            sleep 1
            ((elapsed++))
        done
        
        echo ""
        
        if [ "$success" = true ]; then
            echo "OpenSearch is ready after ${elapsed} seconds!"
            OPENSEARCH_CONTAINER_ID="$container_id"
            return 0
        else
            echo "Timeout waiting for OpenSearch to start after ${max_wait} seconds!"
            echo "Final container logs:"
            docker logs "$container_id"
            return 1
        fi
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

    local routing_shards_setting=""
    if [ "$with_routing_shards" = true ]; then
        routing_shards_setting=",\n                    \"number_of_routing_shards\": \"${NUMBER_OF_ROUTING_SHARDS}\""
    fi

    settings=$(cat <<EOF
{
    "settings": {
        "index": {
            "number_of_shards": "${NUMBER_OF_SHARDS}",
            "number_of_replicas": "0",
            "routing_partition_size": "2"${routing_shards_setting}
        }
    },
    "mappings": {
        "_routing": {
            "required": true
        }
    }
}
EOF
    )

    echo "Creating index ${index_name}"
    curl -s -XPUT "${OPENSEARCH_URL}/${index_name}" \
        -H "Content-Type: application/json" \
        -d "$settings" > /dev/null
}

insert_test_documents() {
    local index_name=$1
    local routing_value="42"
    local count=20
    local bulk_file
    bulk_file=$(mktemp)

    echo "Inserting ${count} test documents with routing=${routing_value}"
    for i in $(seq 1 $count); do
        printf '{"index":{"_id":"%s","routing":"%s"}}\n{"client_id":"%s"}\n' \
            "$i" "$routing_value" "$routing_value" >> "$bulk_file"
    done

    curl -s -XPOST "${OPENSEARCH_URL}/${index_name}/_bulk?refresh=true" \
        -H "Content-Type: application/x-ndjson" \
        --data-binary "@${bulk_file}" > /dev/null

    rm -f "$bulk_file"
}

check_shards_distribution() {
    local index_name=$1
    local expected_shards=2
    local shard_count=0

    echo "Checking shard distribution for indexed documents:"
    echo "Shards containing documents:"

    for shard in $(seq 0 $((NUMBER_OF_SHARDS - 1))); do
        local response
        response=$(curl -s -XGET "${OPENSEARCH_URL}/${index_name}/_count?preference=_shards:${shard}" \
            -H "Content-Type: application/json" \
            -d '{"query":{"match_all":{}}}')

        local doc_count
        doc_count=$(echo "$response" | jq '.count')

        if [ "$doc_count" -gt 0 ]; then
            echo "{\"shard\":${shard},\"count\":${doc_count}}"
            shard_count=$((shard_count + 1))
        fi
    done

    if [ "$shard_count" -eq 0 ]; then
        echo "(no indexed documents found)"
    fi

    echo -e "\nResults for ${index_name}:"
    echo "Expected number of shards: ${expected_shards}"
    echo "Actual number of shards: ${shard_count}"
    
    if [ "$shard_count" -eq "$expected_shards" ]; then
        echo "✅ PASS: Documents are correctly distributed across ${expected_shards} shards"
        return 0
    else
        echo "❌ FAIL: Documents are routed to ${shard_count} shard(s) instead of ${expected_shards}"
        return 1
    fi
}

demonstrate_routing_bug() {
    echo "=== Testing with number_of_routing_shards set ==="
    create_index "test_with_routing" true
    insert_test_documents "test_with_routing"
    if check_shards_distribution "test_with_routing"; then
        WITH_ROUTING_RESULT="PASS"
    else
        WITH_ROUTING_RESULT="FAIL"
    fi
    echo

    echo "=== Testing without number_of_routing_shards set ==="
    create_index "test_without_routing" false
    insert_test_documents "test_without_routing"
    if check_shards_distribution "test_without_routing"; then
        WITHOUT_ROUTING_RESULT="PASS"
    else
        WITHOUT_ROUTING_RESULT="FAIL"
    fi
    
    echo -e "\n=== Test Summary ==="
    echo "The bug is present if:"
    echo "1. Test with number_of_routing_shards passes (shows 2 shards)"
    echo "2. Test without number_of_routing_shards fails (shows 1 shard)"
    echo "This demonstrates that routing_partition_size is ignored when number_of_routing_shards is not set"
    echo
    echo "WITH_ROUTING_RESULT=${WITH_ROUTING_RESULT}"
    echo "WITHOUT_ROUTING_RESULT=${WITHOUT_ROUTING_RESULT}"
    if [[ "${WITH_ROUTING_RESULT}" == "PASS" && "${WITHOUT_ROUTING_RESULT}" == "FAIL" ]]; then
        BUG_STATUS="PRESENT"
    elif [[ "${WITH_ROUTING_RESULT}" == "PASS" && "${WITHOUT_ROUTING_RESULT}" == "PASS" ]]; then
        BUG_STATUS="FIXED"
    else
        BUG_STATUS="UNEXPECTED"
    fi
    echo "BUG_STATUS=${BUG_STATUS}"
}

if ! command -v docker &> /dev/null; then
    echo "Docker is not installed. Please install Docker first."
    exit 1
fi

if ! command -v jq &> /dev/null; then
    echo "jq is not installed. Please install jq first."
    exit 1
fi

# Main execution with better error handling
if ! check_opensearch; then
    echo "Failed to start OpenSearch! Exiting."
    exit 1
fi

demonstrate_routing_bug | tee "$TEST_RESULTS_FILE"

if [ -n "$OPENSEARCH_CONTAINER_ID" ]; then
    echo "Stopping OpenSearch container ${OPENSEARCH_CONTAINER_ID}..."
    docker stop "$OPENSEARCH_CONTAINER_ID"
fi
