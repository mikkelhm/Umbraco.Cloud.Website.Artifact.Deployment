#!/bin/bash

# Uploads a deployment artifact to Umbraco Cloud with the v3 direct-to-storage flow.
#
# The v2 endpoint streamed the zip through the Cloud API, which sits behind Cloudflare and
# API Management. A body over 100 MB is rejected there before the API ever sees it, so a
# publish output of any real size cannot get through. The v3 flow avoids that path entirely:
#
#   1. POST .../v3/projects/{projectId}/deployments/artifacts/upload-url
#        -> a pending artifactId and a short-lived, write-only Azure Blob Storage SAS uri
#   2. PUT the zip straight to that uri (Azure Blob Storage, not the Cloud API)
#        -> single Put Blob for a small file, Put Block + Put Block List for anything larger
#   3. POST .../v3/projects/{projectId}/deployments/artifacts/{artifactId}/complete
#        -> Cloud reads the blob back, verifies it against contentMd5 and finalises the artifact
#
# Nothing is deployable until step 3 succeeds, so a failed run leaves nothing to clean up: just
# run it again. The upload uri is a credential; it is masked in the pipeline log and never printed.
#
# Requires: bash, curl, jq, openssl, dd. All are present on GitHub-hosted (windows/ubuntu) and
# Azure DevOps hosted agents.

# Set required variables
projectId="$1"
apiKey="$2"
filePath="$3"
description="$4"
version="$5"
pipelineVendor="$6"

# Not required, defaults to https://api.cloud.umbraco.com
baseUrl="$7"

# Not required. Size of each staged block in MiB (default 8, matching what the API itself uses).
# Azure allows at most 50000 blocks per blob, so raise this for a very large artifact.
blockSizeMb="${UMBRACO_CLOUD_UPLOAD_BLOCK_SIZE_MB:-8}"

if [[ -z "$baseUrl" ]]; then
    baseUrl="https://api.cloud.umbraco.com"
fi
baseUrl="${baseUrl%/}"

if [[ -z "$projectId" || -z "$apiKey" ]]; then
  echo "projectId and apiKey are required"
  exit 1
fi

if [[ -z "$filePath" ]]; then
  echo "filePath is empty"
  exit 1
fi

if [[ ! -f "$filePath" ]]; then
  echo "filePath does not contain a file"
  exit 1
fi

case "$pipelineVendor" in
  GITHUB|AZUREDEVOPS|TESTRUN) ;;
  *)
    echo "Please use one of the supported Pipeline Vendors or enhance script to fit your needs"
    echo "Currently supported are: GITHUB and AZUREDEVOPS"
    exit 1
    ;;
esac

for tool in curl jq openssl dd; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "Required tool '$tool' was not found on PATH"
    exit 1
  fi
done

### Endpoint docs
# https://docs.umbraco.com/umbraco-cloud/set-up/project-settings/umbraco-cicd/umbracocloudapi
#
artifactsUrl="$baseUrl/v3/projects/$projectId/deployments/artifacts"

blockRetries=3
bytesPerMb=1048576
blockSize=$(( blockSizeMb * bytesPerMb ))
maxBlocks=50000

fileSize=$(wc -c < "$filePath" | tr -d ' ')
fileName=$(basename "$filePath")

if [[ "$fileSize" -le 0 ]]; then
  echo "The artifact '$fileName' is empty"
  exit 1
fi

workDir=$(mktemp -d)
responseFile="$workDir/response"
blockFile="$workDir/block"
trap 'rm -rf "$workDir"' EXIT

# --- helpers ------------------------------------------------------------------------------------

# Prints a failed response in a readable way: the Cloud API answers with ProblemDetails json,
# Azure Blob Storage with xml and Cloudflare with an html page.
function print_failure {
  local what="$1"
  local code="$2"
  echo "$what failed - Unexpected API Response Code: $code - More details below"
  if [[ -s "$responseFile" ]]; then
    if jq . "$responseFile" > /dev/null 2>&1; then
      echo "--- Response JSON formatted ---"
      jq . "$responseFile"
    else
      echo "--- Response RAW ---"
      head -c 2000 "$responseFile"
      echo
    fi
  else
    echo "--- Response empty ---"
  fi
  echo "--- Response End ---"
}

# Marks the upload uri as a secret so the pipeline redacts it should it ever reach the log.
function mask_secret {
  local value="$1"
  if [[ "$pipelineVendor" == "GITHUB" ]]; then
    echo "::add-mask::$value"
  elif [[ "$pipelineVendor" == "AZUREDEVOPS" ]]; then
    echo "##vso[task.setsecret]$value"
  fi
}

# Appends a query parameter to the upload uri, which already carries the SAS token in its query.
function add_query {
  local uri="$1"
  local name="$2"
  local value="$3"
  local encoded
  encoded=$(jq -rn --arg v "$value" '$v|@uri')
  if [[ "$uri" == *\?* ]]; then
    echo "$uri&$name=$encoded"
  else
    echo "$uri?$name=$encoded"
  fi
}

# Base64 md5 of a file - what Azure and the complete endpoint expect, rather than the hex of md5sum.
function md5_base64 {
  openssl md5 -binary "$1" | openssl base64 -A
}

# Base64 of a fixed width index, so every block id has the same length - Azure requires that.
function block_id {
  printf '%06d' "$1" | openssl base64 -A
}

# --- 1. request an upload url -------------------------------------------------------------------

echo "Uploading $fileName ($fileSize bytes) to $baseUrl"
echo "1/3 Requesting an upload url"

requestBody=$(jq -n \
  --arg description "$description" \
  --arg version "$version" \
  '{ description: $description, version: $version }')

responseCode=$(curl -s -S -o "$responseFile" -w "%{http_code}" -X POST "$artifactsUrl/upload-url" \
  -H "Umbraco-Cloud-Api-Key: $apiKey" \
  -H "User-Agent: umbraco-cloud-cicd-github-actions" \
  -H "Content-Type: application/json" \
  --retry 3 --retry-delay 2 \
  -d "$requestBody")

if [[ "$responseCode" != "200" ]]; then
  print_failure "Requesting an upload url" "$responseCode"
  exit 1
fi

artifactId=$(jq -r '.artifactId // empty' "$responseFile")
uploadUri=$(jq -r '.uploadUri // empty' "$responseFile")
blobType=$(jq -r '.blobType // empty' "$responseFile")
maxUploadBytes=$(jq -r '.maxUploadBytes // empty' "$responseFile")

if [[ -z "$artifactId" || -z "$uploadUri" ]]; then
  echo "The API did not return an artifactId and an uploadUri"
  print_failure "Requesting an upload url" "$responseCode"
  exit 1
fi

# The uri is a write credential. Log where it points, never the token on the end of it.
mask_secret "$uploadUri"
echo "    artifact $artifactId -> ${uploadUri%%\?*}"

if [[ -n "$blobType" && "$blobType" != "BlockBlob" ]]; then
  echo "The API asked for blob type '$blobType', which this script cannot write"
  exit 1
fi

if [[ "$maxUploadBytes" =~ ^[0-9]+$ ]] && [[ "$fileSize" -gt "$maxUploadBytes" ]]; then
  echo "The artifact is $fileSize bytes, over the maximum of $maxUploadBytes bytes the API will accept"
  exit 1
fi

# --- 2. upload the content straight to storage --------------------------------------------------

fileMd5=$(md5_base64 "$filePath")

if [[ "$fileSize" -le "$blockSize" ]]; then
  echo "2/3 Uploading content ($(( fileSize / bytesPerMb )) MiB, single request)"

  # On a single Put Blob the service verifies Content-MD5 against the bytes that arrive and keeps
  # it as the blob's Content-MD5.
  responseCode=$(curl -s -S -o "$responseFile" -w "%{http_code}" -X PUT "$uploadUri" \
    -H "x-ms-blob-type: BlockBlob" \
    -H "Content-Type: application/zip" \
    -H "Content-MD5: $fileMd5" \
    -H "Expect:" \
    --upload-file "$filePath")

  if [[ "$responseCode" != "201" ]]; then
    print_failure "Uploading the artifact content" "$responseCode"
    exit 1
  fi
else
  blockCount=$(( (fileSize + blockSize - 1) / blockSize ))
  if [[ "$blockCount" -gt "$maxBlocks" ]]; then
    echo "$fileName needs $blockCount blocks of $blockSizeMb MiB, over the $maxBlocks block limit. Raise UMBRACO_CLOUD_UPLOAD_BLOCK_SIZE_MB."
    exit 1
  fi

  echo "2/3 Uploading content ($(( fileSize / bytesPerMb )) MiB in $blockCount blocks of $blockSizeMb MiB)"

  blockIds=()
  for (( index = 0; index < blockCount; index++ )); do
    # Copy one block out of the artifact so the file is never read into memory in full.
    dd if="$filePath" of="$blockFile" bs="$blockSize" skip="$index" count=1 status=none
    blockLength=$(wc -c < "$blockFile" | tr -d ' ')

    currentBlockId=$(block_id "$index")
    blockUri=$(add_query "$(add_query "$uploadUri" comp block)" blockid "$currentBlockId")
    # The service rejects the block with a 400 if the bytes that arrived do not match this.
    blockMd5=$(md5_base64 "$blockFile")

    attempt=0
    while true; do
      attempt=$(( attempt + 1 ))
      responseCode=$(curl -s -S -o "$responseFile" -w "%{http_code}" -X PUT "$blockUri" \
        -H "Content-Type: application/octet-stream" \
        -H "Content-MD5: $blockMd5" \
        -H "Expect:" \
        --upload-file "$blockFile")

      if [[ "$responseCode" == "201" ]]; then
        break
      fi

      if [[ "$attempt" -ge "$blockRetries" ]]; then
        print_failure "Uploading block $(( index + 1 )) of $blockCount" "$responseCode"
        exit 1
      fi

      backoff=$(( 2 ** attempt ))
      echo "    block $(( index + 1 )) failed with HTTP $responseCode (attempt $attempt of $blockRetries), retrying in ${backoff}s"
      sleep "$backoff"
    done

    blockIds+=("$currentBlockId")
    echo "    block $(( index + 1 ))/$blockCount uploaded ($blockLength bytes)"
  done

  echo "    committing $blockCount blocks"

  blockListXml='<?xml version="1.0" encoding="utf-8"?><BlockList>'
  for id in "${blockIds[@]}"; do
    blockListXml+="<Latest>$id</Latest>"
  done
  blockListXml+='</BlockList>'

  # x-ms-blob-content-md5 stores the assembled blob's Content-MD5 so it can be read back off the
  # blob later. Azure does not validate it here; the per-block Content-MD5 above did that work.
  responseCode=$(curl -s -S -o "$responseFile" -w "%{http_code}" -X PUT "$(add_query "$uploadUri" comp blocklist)" \
    -H "Content-Type: application/xml" \
    -H "x-ms-blob-content-type: application/zip" \
    -H "x-ms-blob-content-md5: $fileMd5" \
    -H "Expect:" \
    --data-binary "$blockListXml")

  if [[ "$responseCode" != "201" ]]; then
    print_failure "Committing the block list" "$responseCode"
    exit 1
  fi
fi

echo "    uploaded $fileSize bytes, content-md5 $fileMd5"

# --- 3. complete the upload ---------------------------------------------------------------------

echo "3/3 Completing the upload"

completeBody=$(jq -n --arg contentMd5 "$fileMd5" '{ contentMd5: $contentMd5 }')

# Cloud reads the whole stored artifact back and hashes it inside this request, so it takes time in
# proportion to the artifact's size. Completing again with the same checksum is safe.
responseCode=$(curl -s -S -o "$responseFile" -w "%{http_code}" -X POST "$artifactsUrl/$artifactId/complete" \
  -H "Umbraco-Cloud-Api-Key: $apiKey" \
  -H "User-Agent: umbraco-cloud-cicd-github-actions" \
  -H "Content-Type: application/json" \
  --retry 3 --retry-delay 2 \
  -d "$completeBody")

if [[ "$responseCode" != "200" ]]; then
  print_failure "Completing the artifact upload" "$responseCode"
  exit 1
fi

completedArtifactId=$(jq -r '.artifactId // empty' "$responseFile")
if [[ -z "$completedArtifactId" ]]; then
  echo "The complete response did not contain an artifactId"
  print_failure "Completing the artifact upload" "$responseCode"
  exit 1
fi

## Write the artifact id to the pipeline variables for use in a later step
if [[ "$pipelineVendor" == "GITHUB" ]]; then
  echo "artifactId=$completedArtifactId" >> "$GITHUB_OUTPUT"
elif [[ "$pipelineVendor" == "AZUREDEVOPS" ]]; then
  echo "##vso[task.setvariable variable=artifactId;isOutput=true]$completedArtifactId"
elif [[ "$pipelineVendor" == "TESTRUN" ]]; then
  echo "$pipelineVendor"
fi

echo "Artifact uploaded - Artifact Id: $completedArtifactId"
echo "--- Upload Response ---"
# blobUrl is left out on purpose: it can carry a read credential for the stored artifact.
jq '{ artifactId, fileName, fileSize, createdUtc, description, version }' "$responseFile"

exit 0
