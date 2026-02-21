public with sharing class PiiMaskingController {

    @AuraEnabled
    public static Id startMasking(List<String> selectedObjects) {
        List<String> objectList;
        
        if (selectedObjects != null && !selectedObjects.isEmpty()) {
            objectList = selectedObjects;
        } else {
            List<PII_Mask_Config__mdt> configs = [SELECT Object_API_Name__c FROM PII_Mask_Config__mdt WHERE Active__c = true];
            Set<String> uniqueObjects = new Set<String>();
            for (PII_Mask_Config__mdt config : configs) {
                uniqueObjects.add(config.Object_API_Name__c);
            }
            objectList = new List<String>(uniqueObjects);
        }
        
        if (!objectList.isEmpty()) {
            return Database.executeBatch(new SandboxDataMasker(objectList));
        }
        return null;
    }

    @AuraEnabled
    public static List<Map<String, Object>> getConfigs() {
        List<Map<String, Object>> result = new List<Map<String, Object>>();
        for (PII_Mask_Config__mdt config : [
            SELECT DeveloperName, Object_API_Name__c, Field_API_Name__c, Masking_Type__c, Pattern__c
            FROM PII_Mask_Config__mdt
            WHERE Active__c = true
            ORDER BY Object_API_Name__c
        ]) {
            Map<String, Object> row = new Map<String, Object>();
            row.put('id', config.DeveloperName);
            row.put('objectName', config.Object_API_Name__c);
            
            // Show fields as readable list
            String fields = config.Field_API_Name__c;
            if (String.isNotBlank(fields) && fields != '(auto-detect)') {
                // Count fields
                List<String> fieldList = fields.split(',');
                row.put('fieldCount', fieldList.size() + ' fields');
                row.put('fields', fields.replaceAll(',', ', '));
            } else {
                row.put('fieldCount', 'Auto-detect');
                row.put('fields', 'All PII fields auto-detected');
            }
            
            row.put('maskingType', config.Masking_Type__c != null ? config.Masking_Type__c : 'Auto');
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
        for (PII_Mask_Log__c log : [
            SELECT Name, Object_Name__c, Job_Id__c, Status__c, Records_Processed__c,
                   Records_Failed__c, Error_Details__c, Fields_Masked__c, Completed_Date__c
            FROM PII_Mask_Log__c
            ORDER BY Completed_Date__c DESC
            LIMIT 50
        ]) {
            Map<String, Object> row = new Map<String, Object>();
            row.put('id', log.Name);
            row.put('objectName', log.Object_Name__c);
            row.put('status', log.Status__c);
            row.put('recordsProcessed', log.Records_Processed__c);
            row.put('recordsFailed', log.Records_Failed__c);
            row.put('fieldsMasked', log.Fields_Masked__c);
            row.put('errorDetails', log.Error_Details__c);
            row.put('completedDate', log.Completed_Date__c);
            row.put('jobId', log.Job_Id__c);
            result.add(row);
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

    // Save object config with selected fields. Same developer name = overrides existing.
    @AuraEnabled
    public static String addObjectConfig(String objectName, String fieldsCsv) {
        try {
            Metadata.CustomMetadata cmd = new Metadata.CustomMetadata();
            // Same developer name per object → upsert behavior
            String devName = objectName.replaceAll('[^a-zA-Z0-9_]', '_');
            
            cmd.fullName = 'PII_Mask_Config__mdt.' + devName;
            cmd.label = objectName;
            
            Metadata.CustomMetadataValue objField = new Metadata.CustomMetadataValue();
            objField.field = 'Object_API_Name__c';
            objField.value = objectName;
            cmd.values.add(objField);
            
            // Store the selected field names as comma-separated
            Metadata.CustomMetadataValue fldField = new Metadata.CustomMetadataValue();
            fldField.field = 'Field_API_Name__c';
            fldField.value = String.isNotBlank(fieldsCsv) ? fieldsCsv : '(auto-detect)';
            cmd.values.add(fldField);
            
            Metadata.CustomMetadataValue typeField = new Metadata.CustomMetadataValue();
            typeField.field = 'Masking_Type__c';
            typeField.value = 'Auto';
            cmd.values.add(typeField);
            
            Metadata.CustomMetadataValue activeField = new Metadata.CustomMetadataValue();
            activeField.field = 'Active__c';
            activeField.value = true;
            cmd.values.add(activeField);
            
            Metadata.DeployContainer container = new Metadata.DeployContainer();
            container.addMetadata(cmd);
            
            Metadata.Operations.enqueueDeployment(container, new PiiMaskingDeployCallback());
            
            // Check if this is an override
            List<PII_Mask_Config__mdt> existing = [
                SELECT Id FROM PII_Mask_Config__mdt WHERE DeveloperName = :devName LIMIT 1
            ];
            String msg = existing.isEmpty() 
                ? 'Object "' + objectName + '" added with ' + fieldsCsv.split(',').size() + ' PII fields.'
                : 'Object "' + objectName + '" updated (overridden) with ' + fieldsCsv.split(',').size() + ' PII fields.';
            return msg;
        } catch (Exception e) {
            throw new AuraHandledException('Error saving config: ' + e.getMessage());
        }
    }

    // Soft-delete: set Active__c = false
    @AuraEnabled
    public static String removeConfig(String devName) {
        try {
            Metadata.CustomMetadata cmd = new Metadata.CustomMetadata();
            cmd.fullName = 'PII_Mask_Config__mdt.' + devName;
            cmd.label = devName;
            
            Metadata.CustomMetadataValue activeField = new Metadata.CustomMetadataValue();
            activeField.field = 'Active__c';
            activeField.value = false;
            cmd.values.add(activeField);
            
            Metadata.DeployContainer container = new Metadata.DeployContainer();
            container.addMetadata(cmd);
            Metadata.Operations.enqueueDeployment(container, new PiiMaskingDeployCallback());
            
            return 'Configuration removed.';
        } catch (Exception e) {
            throw new AuraHandledException('Error removing config: ' + e.getMessage());
        }
    }
}
