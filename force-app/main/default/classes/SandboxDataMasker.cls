public class SandboxDataMasker implements Database.Batchable<sObject>, Database.Stateful {
    
    private List<String> objectsToProcess;
    private String currentObject;
    private List<FieldMaskInfo> fieldsToMask;
    
    // Result tracking (Database.Stateful persists across batches)
    private Integer recordsProcessed = 0;
    private Integer recordsFailed = 0;
    private List<String> errors = new List<String>();
    private List<String> failedIds = new List<String>();
    
    // Retry mode: query specific record IDs instead of full table
    private Set<Id> retryRecordIds;
    private Boolean isRetry = false;

    @TestVisible private static List<PII_Mask_Config__mdt> mockConfigs;

    // Inner class to hold field info for masking
    public class FieldMaskInfo {
        public String fieldName;
        public Schema.DisplayType fieldType;
        public String piiCategory; // email, phone, name, address, date, text, url
        public String maskOverride; // null=auto, or explicit override: Static, Random, Suffix
        
        public FieldMaskInfo(String name, Schema.DisplayType fType, String category) {
            this.fieldName = name;
            this.fieldType = fType;
            this.piiCategory = category;
            this.maskOverride = null;
        }
    }

    public SandboxDataMasker(List<String> objects) {
        this.objectsToProcess = objects;
    }
    
    // Retry constructor: processes only specific failed record IDs for one object
    public SandboxDataMasker(String objectName, Set<Id> recordIds) {
        this.objectsToProcess = new List<String>{ objectName };
        this.retryRecordIds = recordIds;
        this.isRetry = true;
    }

    public static void runAll() {
        List<PII_Mask_Config__mdt> configs;
        if (mockConfigs != null) {
            configs = mockConfigs;
        } else {
            configs = [SELECT Object_API_Name__c FROM PII_Mask_Config__mdt WHERE Active__c = true];
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
            return null;
        }
        
        this.currentObject = objectsToProcess[0];
        this.recordsProcessed = 0;
        this.recordsFailed = 0;
        this.errors = new List<String>();
        
        // Load config to check for field overrides
        this.fieldsToMask = getFieldsFromConfig(currentObject);
        
        if (fieldsToMask.isEmpty()) {
            String query = 'SELECT Id FROM ' + currentObject + ' LIMIT 0';
            return Database.getQueryLocator(query);
        }
        
        Set<String> fieldNames = new Set<String>{'Id'};
        for (FieldMaskInfo info : fieldsToMask) {
            fieldNames.add(info.fieldName);
        }
        
        String query = 'SELECT ' + String.join(new List<String>(fieldNames), ',') + ' FROM ' + currentObject;
        
        // If retry mode, filter to specific record IDs
        if (isRetry && retryRecordIds != null && !retryRecordIds.isEmpty()) {
            List<String> idStrings = new List<String>();
            for (Id rid : retryRecordIds) {
                idStrings.add('\'' + String.valueOf(rid) + '\'');
            }
            query += ' WHERE Id IN (' + String.join(idStrings, ',') + ')';
        }
        
        return Database.getQueryLocator(query);
    }

    public void execute(Database.BatchableContext bc, List<sObject> scope) {
        if (fieldsToMask == null || fieldsToMask.isEmpty()) return;
        
        for (sObject record : scope) {
            try {
                for (FieldMaskInfo info : fieldsToMask) {
                    applySmartMask(record, info);
                }
            } catch (Exception e) {
                // Field-level masking error — will still attempt update
                if (errors.size() < 20) {
                    errors.add(record.Id + ': ' + e.getMessage());
                }
            }
        }
        
        // Use allOrNone=false to capture per-record update failures
        List<Database.SaveResult> results = Database.update(scope, false);
        for (Integer i = 0; i < results.size(); i++) {
            if (results[i].isSuccess()) {
                recordsProcessed++;
            } else {
                recordsFailed++;
                String recId = scope[i].Id != null ? String.valueOf(scope[i].Id) : 'unknown';
                failedIds.add(recId);
                if (errors.size() < 20) {
                    String errMsg = '';
                    for (Database.Error err : results[i].getErrors()) {
                        errMsg += err.getMessage() + '; ';
                    }
                    errors.add(recId + ': ' + errMsg);
                }
            }
        }
    }

    public void finish(Database.BatchableContext bc) {
        // Log results to PII_Mask_Log__c
        try {
            PII_Mask_Log__c log = new PII_Mask_Log__c();
            log.Object_Name__c = currentObject;
            log.Job_Id__c = (bc != null) ? String.valueOf(bc.getJobId()) : 'UNKNOWN';
            log.Status__c = recordsFailed > 0 ? 'Partial' : 'Completed';
            log.Records_Processed__c = recordsProcessed;
            log.Records_Failed__c = recordsFailed;
            log.Completed_Date__c = Datetime.now();
            
            // Build fields list
            List<String> fNames = new List<String>();
            if (fieldsToMask != null) {
                for (FieldMaskInfo info : fieldsToMask) {
                    fNames.add(info.fieldName);
                }
            }
            String fieldsStr = String.join(fNames, ',');
            log.Fields_Masked__c = fieldsStr.length() > 255 ? fieldsStr.substring(0, 255) : fieldsStr;
            
            if (!errors.isEmpty()) {
                log.Error_Details__c = String.join(errors, '\n');
                log.Status__c = 'Failed';
            }
            
            // Store failed IDs for retry
            if (!failedIds.isEmpty()) {
                String idsStr = String.join(failedIds, ',');
                log.Failed_Record_Ids__c = idsStr.length() > 32000 ? idsStr.substring(0, 32000) : idsStr;
            }
            
            insert log;
        } catch (Exception e) {
            System.debug('Error creating mask log: ' + e.getMessage());
        }
        
        // Chain next object
        if (objectsToProcess != null && !objectsToProcess.isEmpty()) {
            objectsToProcess.remove(0);
            if (!objectsToProcess.isEmpty()) {
                Database.executeBatch(new SandboxDataMasker(objectsToProcess));
            }
        }
    }

    // ---- Load fields from config with overrides ----
    
    private List<FieldMaskInfo> getFieldsFromConfig(String objectName) {
        // Get the stored config
        String devName = objectName.replaceAll('[^a-zA-Z0-9_]', '_');
        List<PII_Mask_Config__mdt> configs = [
            SELECT Field_API_Name__c FROM PII_Mask_Config__mdt 
            WHERE DeveloperName = :devName AND Active__c = true LIMIT 1
        ];
        
        // Parse stored fields — format: Field1:MaskType,Field2:MaskType,...
        Map<String, String> fieldOverrides = new Map<String, String>();
        Set<String> configuredFieldNames = new Set<String>();
        
        if (!configs.isEmpty() && String.isNotBlank(configs[0].Field_API_Name__c) 
            && configs[0].Field_API_Name__c != '(auto-detect)') {
            for (String entry : configs[0].Field_API_Name__c.split(',')) {
                entry = entry.trim();
                if (entry.contains(':')) {
                    List<String> parts = entry.split(':');
                    configuredFieldNames.add(parts[0].trim());
                    fieldOverrides.put(parts[0].trim(), parts[1].trim());
                } else {
                    configuredFieldNames.add(entry);
                }
            }
        }
        
        // Get auto-detected fields, filter to configured ones
        List<FieldMaskInfo> allDetected = detectPiiFields(objectName);
        List<FieldMaskInfo> result = new List<FieldMaskInfo>();
        
        if (configuredFieldNames.isEmpty()) {
            // No config or auto-detect — use all detected fields
            return allDetected;
        }
        
        for (FieldMaskInfo info : allDetected) {
            if (configuredFieldNames.contains(info.fieldName)) {
                // Apply override if set
                if (fieldOverrides.containsKey(info.fieldName)) {
                    info.maskOverride = fieldOverrides.get(info.fieldName);
                }
                result.add(info);
            }
        }
        return result;
    }

    // ---- Auto-detect PII fields ----
    
    public static List<FieldMaskInfo> detectPiiFields(String objectName) {
        List<FieldMaskInfo> result = new List<FieldMaskInfo>();
        
        Schema.SObjectType objType = Schema.getGlobalDescribe().get(objectName);
        if (objType == null) return result;
        
        Map<String, Schema.SObjectField> fields = objType.getDescribe().fields.getMap();
        
        Map<String, String> namePatterns = new Map<String, String>{
            'email' => 'email', 'phone' => 'phone', 'fax' => 'phone',
            'mobilephone' => 'phone', 'homephone' => 'phone', 'otherphone' => 'phone',
            'firstname' => 'name', 'lastname' => 'name', 'middlename' => 'name',
            'name' => 'name', 'title' => 'name',
            'street' => 'address', 'city' => 'address', 'state' => 'address',
            'postalcode' => 'address', 'zip' => 'address', 'country' => 'address',
            'mailingstreet' => 'address', 'mailingcity' => 'address',
            'mailingstate' => 'address', 'mailingpostalcode' => 'address',
            'mailingcountry' => 'address', 'otherstreet' => 'address',
            'othercity' => 'address', 'otherstate' => 'address',
            'otherpostalcode' => 'address', 'othercountry' => 'address',
            'billingstreet' => 'address', 'billingcity' => 'address',
            'billingstate' => 'address', 'billingpostalcode' => 'address',
            'billingcountry' => 'address', 'shippingstreet' => 'address',
            'shippingcity' => 'address', 'shippingstate' => 'address',
            'shippingpostalcode' => 'address', 'shippingcountry' => 'address',
            'birthdate' => 'date', 'dateofbirth' => 'date',
            'ssn' => 'text', 'socialsecurity' => 'text', 'taxid' => 'text',
            'description' => 'text', 'website' => 'url'
        };
        
        for (String fieldKey : fields.keySet()) {
            Schema.DescribeFieldResult fd = fields.get(fieldKey).getDescribe();
            
            if (!fd.isUpdateable() || !fd.isAccessible()) continue;
            if (fd.isCalculated() || fd.isAutoNumber()) continue;
            
            String apiName = fd.getName();
            String lowerName = apiName.toLowerCase();
            String category = null;
            
            if (fd.getType() == Schema.DisplayType.EMAIL) {
                category = 'email';
            } else if (fd.getType() == Schema.DisplayType.PHONE) {
                category = 'phone';
            } else if (fd.getType() == Schema.DisplayType.URL) {
                category = 'url';
            } else {
                String cleanName = lowerName.replace('__c', '');
                if (namePatterns.containsKey(cleanName)) {
                    category = namePatterns.get(cleanName);
                } else {
                    for (String pattern : namePatterns.keySet()) {
                        if (cleanName.contains(pattern)) {
                            category = namePatterns.get(pattern);
                            break;
                        }
                    }
                }
            }
            
            if (category != null) {
                result.add(new FieldMaskInfo(apiName, fd.getType(), category));
            }
        }
        
        return result;
    }

    // ---- Smart masking by PII category (with override support) ----
    
    private void applySmartMask(sObject record, FieldMaskInfo info) {
        try {
            Object originalValue = record.get(info.fieldName);
            if (originalValue == null) return;
            
            // Determine effective masking strategy
            String strategy = info.maskOverride != null ? info.maskOverride : info.piiCategory;
            Object newValue;
            
            if (strategy == 'email') {
                newValue = 'masked_' + generateRandomStr(6) + '@example.invalid';
            } else if (strategy == 'phone') {
                newValue = '+61 4' + randomDigits(2) + ' ' + randomDigits(3) + ' ' + randomDigits(3);
            } else if (strategy == 'name') {
                newValue = 'Masked_' + generateRandomStr(5);
            } else if (strategy == 'address') {
                newValue = randomDigits(3) + ' Masked Street';
            } else if (strategy == 'date') {
                if (info.fieldType == Schema.DisplayType.DATE) {
                    newValue = Date.today().addDays(-Integer.valueOf(Math.random() * 10950));
                } else if (info.fieldType == Schema.DisplayType.DATETIME) {
                    newValue = Datetime.now().addDays(-Integer.valueOf(Math.random() * 10950));
                } else {
                    newValue = 'XXXX-XX-XX';
                }
            } else if (strategy == 'url') {
                newValue = 'https://masked-' + generateRandomStr(5) + '.example.invalid';
            } else if (strategy == 'Static') {
                newValue = '***MASKED***';
            } else if (strategy == 'Suffix') {
                String orig = String.valueOf(originalValue);
                newValue = orig.substring(0, Math.min(2, orig.length())) + '***';
            } else if (strategy == 'Random') {
                newValue = 'RND_' + generateRandomStr(8);
            } else {
                newValue = 'MASKED_' + generateRandomStr(8);
            }
            
            record.put(info.fieldName, newValue);
        } catch (Exception e) {
            System.debug('Error masking ' + info.fieldName + ' on ' + currentObject + ': ' + e.getMessage());
        }
    }

    private String generateRandomStr(Integer len) {
        String chars = 'abcdefghjkmnpqrstuvwxyz23456789';
        String result = '';
        for (Integer i = 0; i < len; i++) {
            Integer idx = Integer.valueOf(Math.random() * chars.length());
            result += chars.substring(idx, idx + 1);
        }
        return result;
    }

    private String randomDigits(Integer len) {
        String result = '';
        for (Integer i = 0; i < len; i++) {
            result += String.valueOf(Integer.valueOf(Math.random() * 10));
        }
        return result;
    }
}
