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
            row.put('fieldName', config.Field_API_Name__c != null ? config.Field_API_Name__c : '(auto-detect)');
            row.put('maskingType', config.Masking_Type__c != null ? config.Masking_Type__c : 'Auto');
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

    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> getObjects() {
        List<Map<String, String>> result = new List<Map<String, String>>();
        Map<String, Schema.SObjectType> globalDescribe = Schema.getGlobalDescribe();
        
        Map<String, Map<String, String>> sorted = new Map<String, Map<String, String>>();
        List<String> labels = new List<String>();
        
        for (String objName : globalDescribe.keySet()) {
            Schema.SObjectType objType = globalDescribe.get(objName);
            Schema.DescribeSObjectResult descr = objType.getDescribe();
            
            if (!descr.isQueryable() || !descr.isAccessible() || !descr.isUpdateable()) continue;
            String name = descr.getName();
            if (name.endsWith('__History') || name.endsWith('__Share') || 
                name.endsWith('__Feed') || name.endsWith('__Tag') ||
                name.endsWith('__ChangeEvent') || name.contains('__kav') ||
                name.startsWith('Setup') || name.startsWith('Auth')) continue;
            
            String lbl = descr.getLabel() + ' (' + name + ')';
            Map<String, String> item = new Map<String, String>();
            item.put('value', name);
            item.put('label', lbl);
            sorted.put(lbl, item);
            labels.add(lbl);
        }
        
        labels.sort();
        for (String lbl : labels) {
            result.add(sorted.get(lbl));
        }
        return result;
    }

    // Preview auto-detected PII fields for a given object
    @AuraEnabled
    public static List<Map<String, String>> previewPiiFields(String objectName) {
        List<Map<String, String>> result = new List<Map<String, String>>();
        
        List<SandboxDataMasker.FieldMaskInfo> detected = SandboxDataMasker.detectPiiFields(objectName);
        
        for (SandboxDataMasker.FieldMaskInfo info : detected) {
            Map<String, String> item = new Map<String, String>();
            item.put('fieldName', info.fieldName);
            item.put('category', info.piiCategory);
            item.put('fieldType', String.valueOf(info.fieldType));
            result.add(item);
        }
        
        return result;
    }

    // Save object config — just stores the object name, fields are auto-detected at runtime
    @AuraEnabled
    public static String addObjectConfig(String objectName) {
        try {
            Metadata.CustomMetadata cmd = new Metadata.CustomMetadata();
            String devName = objectName.replaceAll('[^a-zA-Z0-9_]', '_');
            
            cmd.fullName = 'PII_Mask_Config__mdt.' + devName;
            cmd.label = objectName;
            
            Metadata.CustomMetadataValue objField = new Metadata.CustomMetadataValue();
            objField.field = 'Object_API_Name__c';
            objField.value = objectName;
            cmd.values.add(objField);
            
            // Leave Field_API_Name__c empty — auto-detect at runtime
            Metadata.CustomMetadataValue fldField = new Metadata.CustomMetadataValue();
            fldField.field = 'Field_API_Name__c';
            fldField.value = '(auto-detect)';
            cmd.values.add(fldField);
            
            Metadata.CustomMetadataValue typeField = new Metadata.CustomMetadataValue();
            typeField.field = 'Masking_Type__c';
            typeField.value = 'Random';
            cmd.values.add(typeField);
            
            Metadata.DeployContainer container = new Metadata.DeployContainer();
            container.addMetadata(cmd);
            
            Metadata.Operations.enqueueDeployment(container, new PiiMaskingDeployCallback());
            
            return 'Object "' + objectName + '" added! PII fields will be auto-detected during masking.';
        } catch (Exception e) {
            throw new AuraHandledException('Error saving config: ' + e.getMessage());
        }
    }
}
