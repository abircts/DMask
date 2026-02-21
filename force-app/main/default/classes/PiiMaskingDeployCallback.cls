/**
 * Deploy callback for PII Mask Config metadata deployments.
 * Logs deployment results to PII_Mask_Log__c on failure (not just System.debug).
 */
public class PiiMaskingDeployCallback implements Metadata.DeployCallback {
    public void handleResult(Metadata.DeployResult result, Metadata.DeployCallbackContext context) {
        if (result.status == Metadata.DeployStatus.Succeeded) {
            System.debug('PII Mask Config deployed successfully.');
        } else {
            // Log failure to PII_Mask_Log__c so it's visible in the dashboard
            String errorMsg = 'Config deployment failed: ' + result.errorMessage;
            System.debug(errorMsg);
            
            try {
                PII_Mask_Log__c log = new PII_Mask_Log__c();
                log.Object_Name__c = 'Config Deployment';
                log.Job_Id__c = 'DEPLOY';
                log.Status__c = 'Failed';
                log.Records_Processed__c = 0;
                log.Records_Failed__c = 1;
                log.Error_Details__c = errorMsg;
                log.Completed_Date__c = Datetime.now();
                log.Fields_Masked__c = 'N/A';
                insert log;
            } catch (Exception e) {
                System.debug('Could not log deploy failure: ' + e.getMessage());
            }
        }
    }
}
