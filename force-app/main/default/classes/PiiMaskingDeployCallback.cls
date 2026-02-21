public class PiiMaskingDeployCallback implements Metadata.DeployCallback {
    public void handleResult(Metadata.DeployResult result, Metadata.DeployCallbackContext context) {
        if (result.status == Metadata.DeployStatus.Succeeded) {
            System.debug('PII Mask Config deployed successfully.');
        } else {
            System.debug('PII Mask Config deployment failed: ' + result.errorMessage);
        }
    }
}
