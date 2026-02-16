public class SandboxDataMasker implements Database.Batchable<sObject>, Database.Stateful {
    
    private List<String> objectsToProcess;
    private List<PII_Mask_Config__mdt> currentConfigs;
    private String currentObject;

    @TestVisible private static List<PII_Mask_Config__mdt> mockConfigs;

    public SandboxDataMasker(List<String> objects) {
        this.objectsToProcess = objects;
    }

    public static void runAll() {
        List<PII_Mask_Config__mdt> configs;
        if (mockConfigs != null) {
            configs = mockConfigs;
        } else {
            configs = [SELECT Object_API_Name__c FROM PII_Mask_Config__mdt];
        }

        Set<String> uniqueObjects = new Set<String>();
        for (PII_Mask_Config__mdt config : configs) {
            uniqueObjects.add(config.Object_API_Name__c);
        }
        
        List<String> objectList = new List<String>(uniqueObjects);
        if (!objectList.isEmpty()) {
            Database.executeBatch(new SandboxDataMasker(objectList));
        } else {
            System.debug('No PII Mask Configurations found.');
        }
    }

    public Database.QueryLocator start(Database.BatchableContext bc) {
        if (objectsToProcess == null || objectsToProcess.isEmpty()) {
            return null; // Should not happen if confirmed in runAll
        }
        
        this.currentObject = objectsToProcess[0];
        
        // Fetch configs for the current object
        if (mockConfigs != null) {
            this.currentConfigs = new List<PII_Mask_Config__mdt>();
            for (PII_Mask_Config__mdt c : mockConfigs) {
                if (c.Object_API_Name__c == currentObject) {
                    this.currentConfigs.add(c);
                }
            }
        } else {
            this.currentConfigs = [
                SELECT Field_API_Name__c, Masking_Type__c, Pattern__c 
                FROM PII_Mask_Config__mdt 
                WHERE Object_API_Name__c = :currentObject
            ];
        }
        
        // Build generic query
        // Ensure we only query if the object and fields adhere to schema
        
        Set<String> fieldsToQuery = new Set<String>{'Id'};
        for (PII_Mask_Config__mdt config : currentConfigs) {
            fieldsToQuery.add(config.Field_API_Name__c);
        }
        
        String query = 'SELECT ' + String.join(new List<String>(fieldsToQuery), ',') + ' FROM ' + currentObject;
        return Database.getQueryLocator(query);
    }

    public void execute(Database.BatchableContext bc, List<sObject> scope) {
        for (sObject record : scope) {
            for (PII_Mask_Config__mdt config : currentConfigs) {
                applyMask(record, config);
            }
        }
        update scope;
    }

    public void finish(Database.BatchableContext bc) {
        if (objectsToProcess != null && !objectsToProcess.isEmpty()) {
            objectsToProcess.remove(0); // Remove the one we just finished
            
            if (!objectsToProcess.isEmpty()) {
                // Chain the next batch
                Database.executeBatch(new SandboxDataMasker(objectsToProcess));
            }
        }
    }

    private void applyMask(sObject record, PII_Mask_Config__mdt config) {
        String field = config.Field_API_Name__c;
        String type = config.Masking_Type__c;
        String pattern = config.Pattern__c;
        
        try {
            // Check if field exists on record (dynamic check might be needed if config is stale, but try-catch handles it)
            // if (record.get(field) == null) return; // Optional: don't mask if null? Or mask anyway? Usually mask existing data.
            
            Object originalValue = record.get(field);
            if (originalValue == null) return; // Skip nulls
            
            Object newValue = originalValue;

            if (type == 'Static') {
                newValue = pattern != null ? pattern : 'MASKED';
            } else if (type == 'Suffix') {
                String strVal = String.valueOf(originalValue);
                String suffix = pattern != null ? pattern : '.invalid';
                if (!strVal.endsWith(suffix)) {
                   newValue = strVal + suffix;
                }
            } else if (type == 'Random') {
                 // Simple random string or specific types based on field type could be added here
                 // For now, just a random string
                 newValue = 'Masked_' + Integer.valueOf(Math.random() * 100000);
            }
            
            record.put(field, newValue);
        } catch (Exception e) {
            System.debug('Error masking field ' + field + ' on ' + currentObject + ': ' + e.getMessage());
        }
    }
}
