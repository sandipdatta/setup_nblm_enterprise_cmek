# NotebookLM Enterprise CMEK Setup Script

## 1. Overview

This script automates the process of setting up a Customer-Managed Encryption Key (CMEK) for use with NotebookLM Enterprise on Google Cloud. It is designed to simplify the initial configuration by handling the following tasks:

* **API Enablement**: Enables the necessary `Cloud Key Management Service (KMS)` and `Discovery Engine` APIs.
* **KMS Resource Creation**: Creates a KMS Key Ring and a cryptographic Key.
* **IAM Permissions**: Identifies the correct Service Agent accounts for Discovery Engine and Cloud Storage and grants them the necessary `cloudkms.cryptoKeyEncrypterDecrypter` role on the newly created key.

The script is fully interactive and will prompt the user for all required configuration details.

---

## 2. Prerequisites

Before running this script, you must have the **Google Cloud SDK (`gcloud`)** command-line tool installed and authenticated. You can find installation instructions [here](https://cloud.google.com/sdk/docs/install).

---

## 3. How to Use

The script is designed to be run without any command-line arguments.

1.  Make the script executable:
    ```bash
    chmod +x setup_nblm_enterprise_key.sh
    ```

2.  Run the script:
    ```bash
    ./setup_nblm_enterprise_key.sh
    ```

### Interactive Parameters

The script will prompt you to enter the following information:
* **Google Cloud Project ID**: The ID of the project where you want to set up CMEK.
* **Key Ring Name**: The name for the new KMS key ring (e.g., `notebooklm-keyring`).
* **Key Name**: The name for the new KMS key (e.g., `notebooklm-cmek-key`).
* **Protection Level**: Choose between `software` (default) and `hsm` for the key's protection level.

---

## 4. Manual Step: Applying the Key to NotebookLM

**This is a critical step.** After the script successfully completes, the KMS key is created and configured, but it is **not yet active** for NotebookLM. You must manually apply the newly created key within the NotebookLM admin UI settings within your project.

### Known Issue: "Precondition Failed" Error

When you attempt to apply the CMEK key to NotebookLM for the first time, you may encounter a `precondition failed` error. This is a known issue, often caused by internal propagation delays after the IAM permissions have been granted.

**Solution**: If you see this error, please **wait a few minutes and retry** the operation. You may need to attempt to apply the key multiple times until the process succeeds.

---

## 5. Verifying the CMEK Configuration

Once the key has been successfully applied, you can verify its status using the following command. This will show whether the key is active and ready for use by NotebookLM.

Replace `PROJECT_ID` with your project's ID and `LOCATION` with the region for your data store (e.g., `us` or `eu`).

```bash
curl -X GET \
  -H "Authorization: Bearer $(gcloud auth print-access-token)" \
  "[https://LOCATION-discoveryengine.googleapis.com/v1/projects/PROJECT_ID/locations/LOCATION/cmekConfigs]"
```

### Example Output

The output will look similar to the following:
```json
{
  "cmekConfigs": [
    {
      "name": "projects/123456/locations/us/cmekConfigs/cmek-config-1",
      "kmsKey": "projects/key-project-456/locations/us/keyRings/my-key-ring/cryptoKeys/my-key",
      "state": "ACTIVE",
      "isDefault": true,
      "kmsKeyVersion": "projects/key-project-456/locations/us/keyRings/my-key-ring/cryptoKeys/my-key/cryptoKeyVersions/1",
      "notebooklmState": "NOTEBOOK_LM_READY"
    }
  ]
}
```

### Understanding the Status Fields

Pay close attention to the `state` and `notebooklmState` fields, as they change over time:

* `"state"`: This field should change to **`ACTIVE`** approximately 5-10 minutes after the key is successfully applied.
* `"notebooklmState"`: This field will change to **`NOTEBOOK_LM_READY`** after the backend has fully provisioned the key for NotebookLM. This process can take 12-24 hours.

