# WORK IN PROGRESS

Sample Umbraco Cloud website using the **Artifact deployment** project type. Copied from a working
baseline so it can be forked as a starting point.

Dont use unless you know what you are doing.

## Pipeline

`main.yml` builds the site, zips the publish output and uploads it to Umbraco Cloud, then deploys it
by artifact id. Repository secrets `PROJECT_ID` and `UMBRACO_CLOUD_API_KEY` and the variable
`TARGET_ENVIRONMENT_ALIAS` are required; `UMBRACO_CLOUD_API_BASE_URL` optionally overrides the API host.

The upload and the deployment are done by two GitHub Actions from
[mikkelhm/umbraco-cloud-actions](https://github.com/mikkelhm/umbraco-cloud-actions) (work in progress):

- `upload-artifact` uploads the zip with the v3 direct-to-storage flow and outputs the `artifact-id`.
  The zip never travels through the Cloud API, so the 100 MB request limit of the old v2 upload does
  not apply. The ceiling is 2 GiB.
- `deploy` starts the deployment of that artifact on the target environment and waits for it to finish.

The workflows in this repo only pass parameters to those actions. How the Cloud API is called is the
actions' concern, so API changes do not require touching this pipeline.
