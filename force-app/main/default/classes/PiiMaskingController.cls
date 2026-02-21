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

    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> getObjects() {
        List<Map<String, String>> result = new List<Map<String, String>>();
        Map<String, Schema.SObjectType> globalDescribe = Schema.getGlobalDescribe();
        
        for (String objName : globalDescribe.keySet()) {
            Schema.SObjectType objType = globalDescribe.get(objName);
            Schema.DescribeSObjectResult descr = objType.getDescribe();
            
            // Filter: queryable, accessible, not a system/internal object
            if (!descr.isQueryable() || !descr.isAccessible() || !descr.isUpdateable()) continue;
            String name = descr.getName();
            // Skip system objects, history, share, feed, etc.
            if (name.endsWith('__History') || name.endsWith('__Share') || 
                name.endsWith('__Feed') || name.endsWith('__Tag') ||
                name.endsWith('__ChangeEvent') || name.contains('__kav') ||
                name.startsWith('Setup') || name.startsWith('Auth')) continue;
            
            Map<String, String> item = new Map<String, String>();
            item.put('value', name);
            item.put('label', descr.getLabel() + ' (' + name + ')');
            result.add(item);
        }
        
        result.sort();
        return result;
    }

    @AuraEnabled
    public static List<Map<String, String>> getFields(String objectName) {
        List<Map<String, String>> result = new List<Map<String, String>>();
        
        if (String.isBlank(objectName)) return result;
        
        Schema.SObjectType objType = Schema.getGlobalDescribe().get(objectName);
        if (objType == null) return result;
        
        Map<String, Schema.SObjectField> fields = objType.getDescribe().fields.getMap();
        
        // PII-relevant field types
        Set<Schema.DisplayType> piiTypes = new Set<Schema.DisplayType>{
            Schema.DisplayType.STRING,
            Schema.DisplayType.EMAIL,
            Schema.DisplayType.PHONE,
            Schema.DisplayType.TEXTAREA,
            Schema.DisplayType.URL
        };
        
        for (String fieldName : fields.keySet()) {
            Schema.DescribeFieldResult fieldDesc = fields.get(fieldName).getDescribe();
            
            if (!fieldDesc.isUpdateable() || !fieldDesc.isAccessible()) continue;
            if (!piiTypes.contains(fieldDesc.getType())) continue;
            
            Map<String, String> item = new Map<String, String>();
            item.put('value', fieldDesc.getName());
            item.put('label', fieldDesc.getLabel() + ' (' + fieldDesc.getName() + ')');
            result.add(item);
        }
        
        return result;
    }

    @AuraEnabled
    public static String saveConfig(String objectName, String fieldName, String maskingType, String pattern) {
        try {
            Metadata.CustomMetadata cmd = new Metadata.CustomMetadata();
            String devName = objectName + '_' + fieldName;
            // Clean developer name: only alphanumeric + underscore
            devName = devName.replaceAll('[^a-zA-Z0-9_]', '_');
            
            cmd.fullName = 'PII_Mask_Config__mdt.' + devName;
            cmd.label = objectName + ' - ' + fieldName;
            
            Metadata.CustomMetadataValue objField = new Metadata.CustomMetadataValue();
            objField.field = 'Object_API_Name__c';
            objField.value = objectName;
            cmd.values.add(objField);
            
            Metadata.CustomMetadataValue fldField = new Metadata.CustomMetadataValue();
            fldField.field = 'Field_API_Name__c';
            fldField.value = fieldName;
            cmd.values.add(fldField);
            
            Metadata.CustomMetadataValue typeField = new Metadata.CustomMetadataValue();
            typeField.field = 'Masking_Type__c';
            typeField.value = maskingType;
            cmd.values.add(typeField);
            
            if (String.isNotBlank(pattern)) {
                Metadata.CustomMetadataValue patField = new Metadata.CustomMetadataValue();
                patField.field = 'Pattern__c';
                patField.value = pattern;
                cmd.values.add(patField);
            }
            
            Metadata.DeployContainer container = new Metadata.DeployContainer();
            container.addMetadata(cmd);
            
            Metadata.Operations.enqueueDeployment(container, new PiiMaskingDeployCallback());
            
            return 'Configuration saved! It may take a few seconds to appear.';
        } catch (Exception e) {
            throw new AuraHandledException('Error saving config: ' + e.getMessage());
        }
    }
}

