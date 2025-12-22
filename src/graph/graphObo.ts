import { ConfidentialClientApplication } from '@azure/msal-node';

import { getClientCertificateFromEnvOrKeyVault } from '../entra/clientCertificate.js';

function required(name: string, value: string | undefined) {
  if (!value) {
    throw new Error(`Missing required env var: ${name}`);
  }
  return value;
}

function getTenantId() {
  return (
    process.env.GRAPH_TENANT_ID ??
    process.env.TEAMS_APP_TENANT_ID ??
    process.env.AZURE_TENANT_ID
  );
}

function getOboScopes(): string[] {
  const raw = process.env.GRAPH_OBO_SCOPES ?? 'https://graph.microsoft.com/.default';
  return raw.split(/\s+/).filter(Boolean);
}

let cachedClientPromise: Promise<ConfidentialClientApplication> | undefined;
let loggedAuthMode = false;

async function getMsalClient(): Promise<ConfidentialClientApplication> {
  if (cachedClientPromise) return cachedClientPromise;

  cachedClientPromise = (async () => {
    const tenantId = required('GRAPH_TENANT_ID (or TEAMS_APP_TENANT_ID)', getTenantId());
    const clientId = required('GRAPH_CLIENT_ID', process.env.GRAPH_CLIENT_ID);

    const clientSecret = process.env.GRAPH_CLIENT_SECRET;
    if (clientSecret) {
      if (!loggedAuthMode) {
        loggedAuthMode = true;
        console.log('[graph-obo] Using confidential client auth: GRAPH_CLIENT_SECRET');
      }
      return new ConfidentialClientApplication({
        auth: {
          clientId,
          authority: `https://login.microsoftonline.com/${tenantId}`,
          clientSecret
        }
      });
    }

    if (!loggedAuthMode) {
      loggedAuthMode = true;
      const vaultUrl = process.env.GRAPH_CLIENT_CERT_KEYVAULT_URL;
      const secretName = process.env.GRAPH_CLIENT_CERT_SECRET_NAME;
      console.log(
        `[graph-obo] Using confidential client auth: Key Vault certificate (vaultUrl=${vaultUrl ?? '<unset>'}, secretName=${secretName ?? '<unset>'})`
      );
    }

    const { thumbprint, privateKey } = await getClientCertificateFromEnvOrKeyVault();

    return new ConfidentialClientApplication({
      auth: {
        clientId,
        authority: `https://login.microsoftonline.com/${tenantId}`,
        clientCertificate: {
          thumbprint,
          privateKey
        }
      }
    });
  })();

  try {
    return await cachedClientPromise;
  } catch (e) {
    cachedClientPromise = undefined;
    throw e;
  }
}

export type GraphOboResult = {
  accessToken: string;
  scopes: string[];
  expiresAtEpochMs?: number;
};

export async function acquireGraphAccessTokenOnBehalfOf(userAssertion: string): Promise<GraphOboResult> {
  const client = await getMsalClient();
  const scopes = getOboScopes();

  const result = await client.acquireTokenOnBehalfOf({
    oboAssertion: userAssertion,
    scopes
  });

  if (!result?.accessToken) {
    throw new Error('OBO token acquisition returned no access token.');
  }

  return {
    accessToken: result.accessToken,
    scopes,
    expiresAtEpochMs: result.expiresOn?.getTime()
  };
}
