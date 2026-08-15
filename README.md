# WORK IN PROGRESS

Sample Umbraco Cloud website using the **Artifact deployment** project type. Copied from a working
baseline so it can be forked as a starting point.

> **Note:** everything below this block is the stock Umbraco Cloud readme, carried over verbatim.
> It still describes the *git-push / build-on-Cloud* flow, which is **not** what this repo does —
> this repo ships a pre-built `dotnet publish` artifact and deploys with `noBuildAndRestore: true`.
> Rewriting this readme for the artifact flow is a pending follow-up.

## Repository configuration

The pipeline in `.github/workflows/main.yml` needs the following configured in GitHub:

| Type | Name | Purpose |
|---|---|---|
| Secret | `PROJECT_ID` | Umbraco Cloud project id |
| Secret | `UMBRACO_CLOUD_API_KEY` | Cloud API key, for artifact upload + deployment |
| Variable | `TARGET_ENVIRONMENT_ALIAS` | Environment alias to deploy to |
| Variable | `UMBRACO_CLOUD_API_BASE_URL` | *Optional.* Overrides the API base URL. Defaults to `https://api.cloud.umbraco.com` when unset. |

The pipeline needs **only** the two secrets above — enough to upload the artifact and start a
deployment. It deliberately does *not* inject any per-environment configuration into the build.

The artifact is **environment-agnostic**: it carries no project id, no API keys, and no license
keys. Everything environment-specific is applied by Umbraco Cloud as environment variables on the
target environment, which means the same artifact can be promoted between environments unchanged.

## Runtime environment variables

Environment-specific configuration is applied on the target environment rather than committed into
the artifact. There are two distinct sources, and the difference matters.

### Injected by Umbraco Cloud — nothing for you to do

When Cloud provisions an environment it sets that environment's own configuration on the underlying
app service: project and environment identifiers, blob storage, Redis, load balancing, and the
**UmbracoID identity values** that back backoffice login. You do not set these, and you should not
try to — they are managed by the platform and re-applied on its own terms.

The practical consequence: **backoffice login via UmbracoID works on a deployed environment out of
the box.**

### Applied per environment — currently by tooling

| Environment variable | Value / notes |
|---|---|
| `Umbraco__Cloud__Deploy__Settings__ApiKey` | **Secret.** Umbraco Deploy API key. Arbitrary value, but it must be *identical* across environments that need to recognise each other. |
| `Umbraco__CMS__Imaging__HMACSecretKey` | **Secret.** |
| `Umbraco__Licenses__Products__Umbraco.Deploy` | `UMBRACO-CLOUD` |
| `Umbraco__Licenses__Products__Umbraco.Forms` | `UMBRACO-CLOUD` |

### Naming rules

Only the *hierarchy separators* become double underscores. The dots inside `Umbraco.Deploy` and
`Umbraco.Forms` are part of the key name and stay as-is — the same shape ASP.NET Core documents for
[`Logging__LogLevel__Microsoft.Hosting.Lifetime`](https://learn.microsoft.com/aspnet/core/fundamentals/configuration/#how-hierarchical-configuration-data-is-organized).
Environment variable names bind case-insensitively, so casing differences between these and the
platform's own settings are cosmetic.

`Deploy` and `Identity` are root-level sections **inside `umbraco-cloud.json`**, but that file is not
an ASP.NET Core configuration source — its shape does not predict environment-variable names. The
Deploy API key is `Umbraco__Cloud__Deploy__Settings__ApiKey`, not `Deploy__Settings__ApiKey`; assuming
otherwise prevents the site from booting.

### Working locally

A clone of this repo will **not** complete UmbracoID backoffice login locally. `umbraco-cloud.json`
is committed with placeholder identity values (`REPLACE-FROM-YOUR-CLOUD-PROJECT`, all-zero GUIDs),
and the platform-injected values that make login work on a deployed environment are not present on
your machine.

Replace those placeholders with your own project's values to develop locally. There is currently no
supported way to fetch them for a project — providing one is a known gap. Whatever you use locally,
do not commit real values.

---

# Welcome to Umbraco Cloud

In order to run Umbraco locally you will need to [install the .NET 10.0 SDK](https://dotnet.microsoft.com/download) (if you do not have this already).

With dotnet installed, run the following commands in your terminal application of choice:

```
cd src/UmbracoProject
dotnet build
dotnet run
```

The terminal output will show the application starting up and will include localhost URLs which you can use to browse to your local Umbraco site.

The first time the project is run locally, you will see the restore boot up screen from Umbraco Cloud. If the environment you have cloned already contained Umbraco Deploy metadata files (such as Document Types), these will automatically be extracted with the option to restore content from the Cloud environment into the local installation.

```
Note: When running locally, we recommend that you setup a developer certificate and run the website under HTTPS. If you haven't configured one already, then run the following dotnet command:

dotnet dev-certs https --trust
```


## Developing Locally

All you need to know to run your Umbraco Cloud project locally.


### Run locally

Running Umbraco locally will automatically use SQLite out of the box and create a Umbraco.sqlite.db file in `~/umbraco/Data/Umbraco.sqlite.db`. The database schema will be automatically created, so it starts up ready for use.

Browse to the URLs from the terminal output of `dotnet run` to see your Umbraco site or alternatively open the `src/UmbracoProject/UmbracoProject.csproj` file in Visual Studio or JetBrains Rider.

## Project Structure

Below is an overview and description of the different parts contained within this git repository, which makes up your Umbraco Project.
```
.
├── src
│   └── UmbracoProject                              (Project folder - can be renamed)
│       ├── Properties                              
│       │   └──── launchSettings.json               (.NET launch settings file)
│       ├── umbraco                                 
│       │   ├──── Data                              (This folder is where Umbraco data such as local database files, generated models and temporary data is stored)
│       │   ├──── Deploy                            (This folder is where the metadata files from Umbraco Deploy are stored)
│       ├── Views                                   (Directory containing templates, partial views and partial view macros)
│       │   └──── ...
│       ├── wwwroot                                 (Directory containing static assets such as images, CSS and JS)
│       │   └──── ...
│       ├── appsettings.json                        (Umbraco appsettings file)
│       ├── appsettings.Development.json            (Local Development & Cloud Development specific configuration)
│       ├── appsettings.Staging.json                (Cloud Staging specific configuration)
│       ├── appsettings.Production.json             (Cloud Production/Live specfic configuration)
│       ├── Program.cs
│       ├── umbraco-cloud.json                      (Umbraco Cloud specific configuration file - this should only be updated by Umbraco Cloud)
│       └── UmbracoProject.csproj                   (The Project file used to build and run the Umbraco project - can be renamed)
├── .dockerignore                             
├── .editorconfig                           
├── .gitattributes                            
├── .gitignore                            
├── .umbraco                                        (Umbraco Project settings used by Umbraco Cloud to build, run and maintain the project in the git repository)
├── NuGet.config                            
└── Readme.md                                       (This file)
...
```

### Renaming the Project file and folder
The file called `.umbraco` at the root of the project contains the following:

```
[project]
base = "src/UmbracoProject"
csproj = "UmbracoProject.csproj"
```

These two properties help inform us the folder location which contains the application and the second is the name of the .csproj file to build.

You can rename the folder and .csproj file to whatever you want, you may also want to update any C# code namespaces to reflect the name of your project.

In addition to this you are able to add additional Class Library projects that are referenced by the Umbraco application .csproj file, if you prefer to organise your code that way. 

So you could rename `UmbracoProject.csproj` to `MyAwesomeProject.Web.csproj` and have one or more additional class library projects such as `MyAwesomeProject.Code.csproj`

```
[project]
base = "src/MyAwesomeProject.Web"
csproj = "MyAwesomeProject.Web.csproj"
```

It's a good idea to also update the namespace used in the Program.cs and _ViewImports.cshtml files, so the naming is consistent throughout your project structure. Once updated you will need to clear out the bin and obj folders locally to avoid build errors. When you are done, commit the changes and push them to Cloud (and that's it).

### Build Process on Umbraco Cloud
When you push your commits to Umbraco Cloud from your local machine, the build process is as follows:
* The `.umbraco` file is used to determine the location of the Umbraco application and the name of the .csproj file to build with MSBuild
* The csproj file will be restored, built and published to the wwwroot folder
* If the git commit contains any Umbraco Deploy metadata files such as Document Types, then these will be deployed to the environment.
* Any additional files such as views, CSS, JS etc will then be copied over to the website

> Recommendation: When pushing to Umbraco Cloud Git repositories, you should use the terminal or a git desktop application that allows you to view the output. As this shows the build process happening and if you have a build error you would be unaware.

### Adding a Solution file
If you are using Visual Studio you will likely want a solution file, so you and your team can easily work with the Umbraco Cloud project from within Visual Studio and have the option to add additional projects.

From the terminal of your choice navigate to the root of the git repository for your Umbraco Cloud project, and enter the following command.
```
dotnet new sln --name MyAwesomeSolution
```

> Recommendation: When creating a solution file we recommend that you place it in the root of the git repository.

If you want to add additional projects to your solution, you can do that from the command line as well using the following `dotnet` commands
```
dotnet new classlib --name MyAwesomeProject.Code --output src/MyAwesomeProject.Code -f net10.0
dotnet sln add .\src\MyAwesomeProject.Code\MyAwesomeProject.Code.csproj
dotnet sln add .\src\MyAwesomeProject.Web\MyAwesomeProject.Web.csproj
dotnet add .\src\MyAwesomeProject.Web\MyAwesomeProject.Web.csproj reference .\src\MyAwesomeProject.Code\MyAwesomeProject.Code.csproj
```

> Recommendation: When creating new projects along side the default UmbracoProject, we recommend that they are added to the src folder in the git repository.

# Continous Integration and Delivery (CI/CD Flow)
If you are using a CI/CD tool such as Azure DevOps or GitHub Actions, you can use the following documentation to set it up to deploy your Umbraco Cloud project.
[Umbraco Cloud CI/CD flow](https://docs.umbraco.com/umbraco-cloud/set-up/project-settings/umbraco-cicd)


# Documentation

For further documentation please visit [Umbraco Docs](https://docs.umbraco.com/umbraco-cloud)
