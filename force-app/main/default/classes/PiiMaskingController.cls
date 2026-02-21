public with sharing class PiiMaskingController {

    @AuraEnabled
    public static Id startMasking() {
        List<PII_Mask_Config__mdt> configs = [SELECT Object_API_Name__c FROM PII_Mask_Config__mdt];
        
        Set<String> uniqueObjects = new Set<String>();
        for (PII_Mask_Config__mdt config : configs) {
            uniqueObjects.add(config.Object_API_Name__c);
        }
        
        List<String> objectList = new List<String>(uniqueObjects);
        if (!objectList.isEmpty()) {
            return Database.executeBatch(new SandboxDataMasker(objectList));
        }
        return null;
    }

    @AuraEnabled(cacheable=true)
    public static List<Map<String, Object>> getConfigs() {
        List<Map<String, Object>> result = new List<Map<String, Object>>();
        for (PII_Mask_Config__mdt config : [
            SELECT DeveloperName, Object_API_Name__c, Field_API_Name__c, Masking_Type__c, Pattern__c
            FROM PII_Mask_Config__mdt
            ORDER BY Object_API_Name__c, Field_API_Name__c
        ]) {
            Map<String, Object> row = new Map<String, Object>();
            row.put('id', config.DeveloperName);
            row.put('objectName', config.Object_API_Name__c);
            row.put('fieldName', config.Field_API_Name__c);
            row.put('maskingType', config.Masking_Type__c);
            row.put('pattern', config.Pattern__c != null ? config.Pattern__c : '—');
            result.add(row);
        }
        return result;
    }

    @AuraEnabled
    public static List<Map<String, Object>> getActiveJobs() {
        List<Map<String, Object>> result = new List<Map<String, Object>>();
        for (AsyncApexJob job : [
            SELECT Id, Status, JobItemsProcessed, TotalJobItems, NumberOfErrors, 
                   CreatedDate, CompletedDate, ExtendedStatus, ApexClass.Name
            FROM AsyncApexJob
            WHERE ApexClass.Name = 'SandboxDataMasker'
            AND Status IN ('Holding', 'Queued', 'Preparing', 'Processing')
            ORDER BY CreatedDate DESC
            LIMIT 10
        ]) {
            result.add(mapJob(job));
        }
        return result;
    }

    @AuraEnabled
    public static List<Map<String, Object>> getJobHistory() {
        List<Map<String, Object>> result = new List<Map<String, Object>>();
        for (AsyncApexJob job : [
            SELECT Id, Status, JobItemsProcessed, TotalJobItems, NumberOfErrors,
                   CreatedDate, CompletedDate, ExtendedStatus, ApexClass.Name
            FROM AsyncApexJob
            WHERE ApexClass.Name = 'SandboxDataMasker'
            AND Status IN ('Completed', 'Failed', 'Aborted')
            ORDER BY CompletedDate DESC
            LIMIT 10
        ]) {
            result.add(mapJob(job));
        }
        return result;
    }

    private static Map<String, Object> mapJob(AsyncApexJob job) {
        Map<String, Object> row = new Map<String, Object>();
        row.put('id', job.Id);
        row.put('status', job.Status);
        row.put('processed', job.JobItemsProcessed);
        row.put('total', job.TotalJobItems);
        row.put('errors', job.NumberOfErrors);
        row.put('createdDate', job.CreatedDate);
        row.put('completedDate', job.CompletedDate);
        
        Integer pct = 0;
        if (job.TotalJobItems != null && job.TotalJobItems > 0) {
            pct = (Integer) ((Decimal.valueOf(job.JobItemsProcessed) / Decimal.valueOf(job.TotalJobItems)) * 100);
        }
        row.put('progress', pct);
        row.put('extendedStatus', job.ExtendedStatus);
        return row;
    }
}
