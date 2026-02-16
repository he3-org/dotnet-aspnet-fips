# Deploying to Azure App Service with FIPS Enabled

This guide walks through deploying the FIPS-compliant ASP.NET Core Docker image to Azure App Service on Linux with FIPS mode enabled.

## Prerequisites

- **Azure CLI** installed and authenticated (`az login`)
- **Docker** installed and logged in to Docker Hub (`docker login`)
- **Azure Subscription** with permissions to create resources
- **Docker Hub account** (or use Azure Container Registry)

## Step 1: Build and Push the Docker Image

### Build the FIPS Image

```bash
docker build -t your-dockerhub-username/dotnet-aspnet-fips:latest .
```

### Tag the Image

```bash
docker tag your-dockerhub-username/dotnet-aspnet-fips:latest \
  your-dockerhub-username/dotnet-aspnet-fips:10.0
```

### Push to Docker Hub

```bash
docker push your-dockerhub-username/dotnet-aspnet-fips:latest
docker push your-dockerhub-username/dotnet-aspnet-fips:10.0
```

> **Alternative**: Use Azure Container Registry (ACR) instead of Docker Hub for private images.

## Step 2: Create Azure Resources

### Create a Resource Group

```bash
az group create \
  --name rg-your-app \
  --location eastus
```

### Create an App Service Plan (Linux)

```bash
az appservice plan create \
  --name plan-your-app \
  --resource-group rg-your-app \
  --is-linux \
  --sku B1
```

> **Note**: B1 is the Basic tier. For production, consider P1V2 or higher.

### Create the Web App

```bash
az webapp create \
  --name your-app-name \
  --resource-group rg-your-app \
  --plan plan-your-app \
  --deployment-container-image-name your-dockerhub-username/dotnet-aspnet-fips:latest
```

> **Important**: The app name must be globally unique (becomes `your-app-name.azurewebsites.net`).

## Step 3: Enable FIPS Mode

Azure App Service on Linux supports a `linuxFipsModeEnabled` property. Enable it using the `az resource update` command:

```bash
az resource update \
  --ids /subscriptions/YOUR-SUBSCRIPTION-ID/resourceGroups/rg-your-app/providers/Microsoft.Web/sites/your-app-name \
  --set properties.siteConfig.linuxFipsModeEnabled=true
```

**To find your subscription ID:**

```bash
az account show --query id --output tsv
```

**Or use the full command:**

```bash
SUBSCRIPTION_ID=$(az account show --query id --output tsv)
az resource update \
  --ids /subscriptions/$SUBSCRIPTION_ID/resourceGroups/rg-your-app/providers/Microsoft.Web/sites/your-app-name \
  --set properties.siteConfig.linuxFipsModeEnabled=true
```

## Step 4: Configure the Container

If you need to update the container image after initial creation:

```bash
az webapp config container set \
  --name your-app-name \
  --resource-group rg-your-app \
  --container-image-name your-dockerhub-username/dotnet-aspnet-fips:latest
```

### Enable Container Logging

```bash
az webapp log config \
  --name your-app-name \
  --resource-group rg-your-app \
  --docker-container-logging filesystem
```

## Step 5: Restart the Web App

```bash
az webapp restart \
  --name your-app-name \
  --resource-group rg-your-app
```

## Step 6: Verify the Deployment

### Check the App Service Status

```bash
az webapp show \
  --name your-app-name \
  --resource-group rg-your-app \
  --query state \
  --output tsv
```

Expected output: `Running`

### View Container Logs

**Option 1: Azure Portal**

1. Navigate to https://portal.azure.com
2. Go to **Resource Groups** → **rg-your-app** → **your-app-name**
3. Left menu → **Monitoring** → **Log stream**

**Option 2: Azure CLI**

```bash
az webapp log tail \
  --name your-app-name \
  --resource-group rg-your-app
```

### Access the Application

```bash
az webapp show \
  --name your-app-name \
  --resource-group rg-your-app \
  --query defaultHostName \
  --output tsv
```

Open the URL in your browser: `https://your-app-name.azurewebsites.net`

## Step 7: Deploy Your Application Code

This FIPS image is a **runtime-only** image. To deploy your own ASP.NET Core application:

### Option A: Multi-stage Dockerfile

```dockerfile
# Build stage
FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
WORKDIR /src
COPY ["YourApp.csproj", "./"]
RUN dotnet restore "YourApp.csproj"
COPY . .
RUN dotnet publish "YourApp.csproj" -c Release -o /app/publish

# Runtime stage with FIPS
FROM your-dockerhub-username/dotnet-aspnet-fips:latest AS runtime
WORKDIR /app
COPY --from=build /app/publish .
ENTRYPOINT ["dotnet", "YourApp.dll"]
```

Build and push:

```bash
docker build -t your-dockerhub-username/your-app:latest .
docker push your-dockerhub-username/your-app:latest
```

Update the Web App:

```bash
az webapp config container set \
  --name your-app-name \
  --resource-group rg-your-app \
  --container-image-name your-dockerhub-username/your-app:latest

az webapp restart \
  --name your-app-name \
  --resource-group rg-your-app
```

### Option B: Azure Container Registry (ACR)

For private images, use Azure Container Registry:

```bash
# Create ACR
az acr create \
  --name yourregistryname \
  --resource-group rg-your-app \
  --sku Basic

# Build and push to ACR
az acr build \
  --registry yourregistryname \
  --image your-app:latest \
  .

# Configure Web App to use ACR
az webapp config container set \
  --name your-app-name \
  --resource-group rg-your-app \
  --container-image-name yourregistryname.azurecr.io/your-app:latest \
  --container-registry-url https://yourregistryname.azurecr.io
```

## Cleanup

To remove all resources:

```bash
az group delete \
  --name rg-your-app \
  --yes \
  --no-wait
```

This deletes:

- Web App
- App Service Plan
- All configurations

## Troubleshooting

### Container Won't Start

Check the container logs:

```bash
az webapp log tail --name your-app-name --resource-group rg-your-app
```

Common issues:

- **Port binding**: Ensure your app listens on port `8080` or set `WEBSITES_PORT` app setting
- **Startup time**: Increase timeout with `--startup-timeout` setting
- **Environment variables**: Check required app settings are configured

### FIPS Verification

To verify FIPS is active in your running container, use the Azure Portal's SSH console:

1. Azure Portal → Your Web App → **Development Tools** → **SSH**
2. In the console:
    ```bash
    openssl list -providers
    ```

Expected output should show `fips` provider with `status: active`.

### Performance Considerations

- **App Service Plan Size**: B1 is suitable for testing. Use P1V2 or higher for production.
- **Always On**: Enable "Always On" in Configuration → General Settings to prevent cold starts
- **Health Check**: Configure health check endpoints for better availability
- **Scaling**: Consider scaling out (multiple instances) rather than scaling up for high traffic

## Additional Configuration

### Custom Domain and SSL

```bash
# Add custom domain
az webapp config hostname add \
  --webapp-name your-app-name \
  --resource-group rg-your-app \
  --hostname www.yourdomain.com

# Bind SSL certificate (managed certificate - free)
az webapp config ssl create \
  --name your-app-name \
  --resource-group rg-your-app \
  --hostname www.yourdomain.com
```

### Application Settings

Set environment variables for your application:

```bash
az webapp config appsettings set \
  --name your-app-name \
  --resource-group rg-your-app \
  --settings \
    ASPNETCORE_ENVIRONMENT=Production \
    PFX_PASSWORD="your-certificate-password" \
    CustomSetting=Value
```

**Note:** If your application loads PKCS#12 certificates (`.p12` or `.pfx` files), set the `PFX_PASSWORD` environment variable to the certificate password. The FipsValidation test app requires this for certificate loading tests.

### Continuous Deployment

For continuous deployment from GitHub Actions, Azure DevOps, or other CI/CD tools, use deployment credentials:

```bash
az webapp deployment list-publishing-credentials \
  --name your-app-name \
  --resource-group rg-your-app
```

## References

- [Azure App Service Documentation](https://docs.microsoft.com/azure/app-service/)
- [Deploy Custom Containers to App Service](https://docs.microsoft.com/azure/app-service/configure-custom-container)
- [FIPS Compliance Documentation](./FIPS-COMPLIANCE.md)
- [Azure CLI Reference](https://docs.microsoft.com/cli/azure/)
