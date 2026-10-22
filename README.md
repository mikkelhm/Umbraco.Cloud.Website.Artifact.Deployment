# Umbraco Cloud – Artifact Deployment template

> **Work in progress.** The Artifact deployment project type and the GitHub Actions this template uses
> are still in development. Expect changes.

A starting point for an Umbraco Cloud project that uses the **Artifact deployment** project type. You
build the site in GitHub Actions, upload the result to Umbraco Cloud as a zip (the *artifact*), and
Cloud deploys that zip as-is. Nothing is built on Cloud.

The site is Umbraco 18 on .NET 10, with Umbraco Forms and Umbraco Deploy.

## Setup

### Before you start

- An Umbraco Cloud project of type **Artifact deployment**. The deployment type is chosen when the
  project is created. Picking it is not yet open to every account.
- A GitHub account that can see this template repository.

### 1. Create your repository

1. Click **Use this template** → **Create a new repository** on this repository's GitHub page.
2. Choose an owner and a name, and create it. A private repository is fine.

Creating the repository starts a pipeline run straight away. It is skipped, because the repository is
not connected to Cloud yet. That is expected.

### 2. Get the CI/CD details from Umbraco Cloud

Open your project in the Umbraco Cloud Portal and go to its **CI/CD** page. Note down:

| What | Used for |
|------|----------|
| Project Id | the `PROJECT_ID` secret |
| Primary API key | the `UMBRACO_CLOUD_API_KEY` secret |
| The alias of the environment to deploy to (`live` on a new project) | the `TARGET_ENVIRONMENT_ALIAS` variable |

CI/CD and *Deploy to any target* are switched on automatically for Artifact deployment projects.

### 3. Add the secrets and variables to GitHub

All four values are **repository-level Actions** values. In your new repository:

1. Open the **Settings** tab (top of the repository page, not your account settings).
2. In the left menu, under **Security**, expand **Secrets and variables** and click **Actions**.
3. The page has two tabs, **Secrets** and **Variables**. Each has a **Repository** section with a
   **New repository secret** / **New repository variable** button.

On the **Secrets** tab, click **New repository secret** for each of these:

| Name | Value | Why a secret |
|------|-------|--------------|
| `PROJECT_ID` | Project Id from step 2 | Identifies your project to the Cloud API |
| `UMBRACO_CLOUD_API_KEY` | Primary API key from step 2 | A credential; GitHub hides it in logs |

On the **Variables** tab, click **New repository variable** for each of these:

| Name | Value | Why a variable |
|------|-------|----------------|
| `TARGET_ENVIRONMENT_ALIAS` | Environment alias from step 2, e.g. `live` | The pipeline checks it to decide whether to run at all, and only variables can be checked there |
| `UMBRACO_CLOUD_API_BASE_URL` | *Optional.* Leave it out to use `https://api.cloud.umbraco.com` | Not sensitive |

Get these wrong and the pipeline fails quietly or not at all:

- **Use the Actions page, not Codespaces or Dependabot.** Those are separate stores under the same
  menu, and the pipeline does not read them.
- **Use Repository, not Environment.** Secrets and variables scoped to a GitHub *Environment* are not
  read by these workflows.
- **`TARGET_ENVIRONMENT_ALIAS` must be a variable.** Added as a secret, every run is skipped without
  an error.

### 4. Allow workflows to write

The Dependabot auto-merge (see [Things worth knowing](#things-worth-knowing)) merges pull requests
and starts the deployment, so it needs write access.

1. In the repository, open **Settings**.
2. In the left menu, expand **Actions** (under **Code and automation**) and click **General**.
3. Scroll to the bottom, to the **Workflow permissions** section.
4. Select **Read and write permissions** and click **Save**.

Leave **Allow GitHub Actions to create and approve pull requests** unticked; it is not needed.

If **Read and write permissions** is greyed out, your organization sets it for all its repositories.
An organization owner can change it under the organization's **Settings** → **Actions** →
**General** → **Workflow permissions**.

### 5. Run the first deployment

1. Go to the **Actions** tab, select **pipeline** and click **Run workflow** on `main`.
2. Wait for both jobs, *Prepare and Upload Artifact* and *Deploy to Cloud*, to go green. The deploy
   job waits for Cloud and fails if the deployment fails.
3. Open the environment's URL. A `503` "Site is Being Upgraded" right after the deployment means the
   site is still starting; give it a minute.

From now on, every push to `main` builds and deploys.

### 6. Log in to the backoffice

Log in on the deployed site with your Umbraco ID, as on any Cloud project. Cloud sets the Umbraco ID
and Deploy settings on the environment itself; you do not configure them.

## Working locally

```bash
dotnet run --project src/UmbracoProject
```

Umbraco ID login **does not work locally** yet. `src/UmbracoProject/umbraco-cloud.json` only holds
placeholder values (`REPLACE-FROM-YOUR-CLOUD-PROJECT` and all-zero ids), and there is no supported way
to fetch a project's real values yet.

Do not commit real secrets to `umbraco-cloud.json` or `appsettings*.json`. The artifact is meant to be
environment-agnostic: anything per environment comes from Cloud, not from the zip.

## What is in the repository

| File | What it does |
|------|--------------|
| `.github/workflows/main.yml` | Runs on push to `main` (or by hand). Builds, uploads and deploys to `TARGET_ENVIRONMENT_ALIAS`. |
| `.github/workflows/cloud-artifact.yml` | Publishes the site, zips it and uploads the zip. Outputs the artifact id. |
| `.github/workflows/cloud-deployment.yml` | Deploys an artifact id to an environment. Can also be run by hand to redeploy an earlier artifact. |
| `.github/workflows/main-multi-envs.yml` | Sample that builds once and promotes the same artifact through dev → stage → live. |
| `.github/workflows/pull-request.yml` | Builds every pull request and checks the zip size. Merges Dependabot patch/minor updates once the build passes. |
| `.github/dependabot.yml` | Daily NuGet updates, monthly GitHub Actions updates. |
| `Directory.Packages.props` | All package versions (central package management). |

### How the pipeline talks to Cloud

The upload and the deployment are done by two GitHub Actions from
[mikkelhm/umbraco-cloud-actions](https://github.com/mikkelhm/umbraco-cloud-actions) (work in progress):

- `upload-artifact` uploads the zip straight to storage and outputs the `artifact-id`. The zip never
  passes through the Cloud API, so the 100 MB limit of the old upload does not apply. The limit is
  2 GiB; `pull-request.yml` fails a build whose zip passes 1800 MB.
- `deploy` starts the deployment of that artifact on the target environment and waits for it to finish.

The workflows only pass parameters to those actions, so changes to the Cloud API do not require
changes to your pipeline.

### Things worth knowing

- **Dependabot updates deploy themselves.** Patch and minor package updates are merged automatically
  when the pull request builds, and the merge starts `main.yml`. Major updates (for example a new
  Umbraco major) always wait for you.
- **More than one environment.** Use `main-multi-envs.yml`. Add the `STAGE_ENVIRONMENT_ALIAS` and
  `LIVE_ENVIRONMENT_ALIAS` variables, and read the comments at the top of the file first: only one of
  the two pipelines should trigger on push, or both deploy at once and Cloud rejects one of them.
- **Runner.** The build runs on `ubuntu-latest`, which is faster and cheaper than Windows and produces
  a working artifact. `cloud-artifact.yml` lists when to switch to `windows-latest`. If you do, switch
  `pull-request.yml` too.
- **Your repository is a copy.** Later changes to this template do not reach repositories created
  from it.
