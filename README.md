# WORK IN PROGRESS

Sample Umbraco Cloud website using the **Artifact deployment** project type. Copied from a working
baseline so it can be forked as a starting point.

Dont use unless you know what you are doing.

## Pipeline

`main.yml` builds the site, zips the publish output and uploads it to Umbraco Cloud, then deploys it
by artifact id. Repository secrets `PROJECT_ID` and `UMBRACO_CLOUD_API_KEY` and the variable
`TARGET_ENVIRONMENT_ALIAS` are required; `UMBRACO_CLOUD_API_BASE_URL` optionally overrides the API host.

The upload (`.github/scripts/upload_artifact.sh`) uses the **v3 direct-to-storage** endpoints:

1. `POST /v3/projects/{projectId}/deployments/artifacts/upload-url` returns a pending `artifactId` and a
   short-lived, write-only blob SAS url.
2. The zip is `PUT` straight to Azure Blob Storage, as one request for small files and as
   Put Block + Put Block List (8 MiB blocks, per-block `Content-MD5`, retried) for anything larger.
3. `POST /v3/projects/{projectId}/deployments/artifacts/{artifactId}/complete` with the file's base64
   md5 makes Cloud verify the stored content and finalise the artifact.

The zip never travels through the Cloud API, so the 100 MB Cloudflare request limit that capped the
v2 upload endpoint does not apply. The ceiling is the 2 GiB the complete endpoint enforces. The SAS url
is a credential and is masked in the pipeline log. Set `UMBRACO_CLOUD_UPLOAD_BLOCK_SIZE_MB` to change
the block size.
