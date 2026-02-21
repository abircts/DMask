public class SandboxDataMasker implements Database.Batchable<sObject>, Database.Stateful {
    
    private List<String> objectsToProcess;
    private String currentObject;
    private List<FieldMaskInfo> fieldsToMask;

    @TestVisible private static List<PII_Mask_Config__mdt> mockConfigs;

    // Inner class to hold field info for masking
    public class FieldMaskInfo {
        public String fieldName;
        public Schema.DisplayType fieldType;
        public String piiCategory; // email, phone, name, address, date, text, number
        
        public FieldMaskInfo(String name, Schema.DisplayType fType, String category) {
            this.fieldName = name;
            this.fieldType = fType;
            this.piiCategory = category;
        }
    }

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
            return null;
        }
        
        this.currentObject = objectsToProcess[0];
        this.fieldsToMask = detectPiiFields(currentObject);
        
        if (fieldsToMask.isEmpty()) {
            // No PII fields found — build minimal query so batch can finish
            String query = 'SELECT Id FROM ' + currentObject + ' LIMIT 0';
            return Database.getQueryLocator(query);
        }
        
        Set<String> fieldNames = new Set<String>{'Id'};
        for (FieldMaskInfo info : fieldsToMask) {
            fieldNames.add(info.fieldName);
        }
        
        String query = 'SELECT ' + String.join(new List<String>(fieldNames), ',') + ' FROM ' + currentObject;
        return Database.getQueryLocator(query);
    }

    public void execute(Database.BatchableContext bc, List<sObject> scope) {
        if (fieldsToMask == null || fieldsToMask.isEmpty()) return;
        
        for (sObject record : scope) {
            for (FieldMaskInfo info : fieldsToMask) {
                applySmartMask(record, info);
            }
        }
        update scope;
    }

    public void finish(Database.BatchableContext bc) {
        if (objectsToProcess != null && !objectsToProcess.isEmpty()) {
            objectsToProcess.remove(0);
            if (!objectsToProcess.isEmpty()) {
                Database.executeBatch(new SandboxDataMasker(objectsToProcess));
            }
        }
    }

    // ---- Auto-detect PII fields ----
    
    public static List<FieldMaskInfo> detectPiiFields(String objectName) {
        List<FieldMaskInfo> result = new List<FieldMaskInfo>();
        
        Schema.SObjectType objType = Schema.getGlobalDescribe().get(objectName);
        if (objType == null) return result;
        
        Map<String, Schema.SObjectField> fields = objType.getDescribe().fields.getMap();
        
        // PII field name patterns (case-insensitive matching)
        Map<String, String> namePatterns = new Map<String, String>{
            'email' => 'email',
            'phone' => 'phone',
            'fax' => 'phone',
            'mobilephone' => 'phone',
            'homephone' => 'phone',
            'otherphone' => 'phone',
            'firstname' => 'name',
            'lastname' => 'name',
            'middlename' => 'name',
            'name' => 'name',
            'street' => 'address',
            'city' => 'address',
            'state' => 'address',
            'postalcode' => 'address',
            'zip' => 'address',
            'country' => 'address',
            'mailingstreet' => 'address',
            'mailingcity' => 'address',
            'mailingstate' => 'address',
            'mailingpostalcode' => 'address',
            'mailingcountry' => 'address',
            'otherstreet' => 'address',
            'othercity' => 'address',
            'otherstate' => 'address',
            'otherpostalcode' => 'address',
            'othercountry' => 'address',
            'billingstreet' => 'address',
            'billingcity' => 'address',
            'billingstate' => 'address',
            'billingpostalcode' => 'address',
            'billingcountry' => 'address',
            'shippingstreet' => 'address',
            'shippingcity' => 'address',
            'shippingstate' => 'address',
            'shippingpostalcode' => 'address',
            'shippingcountry' => 'address',
            'birthdate' => 'date',
            'dateofbirth' => 'date',
            'ssn' => 'text',
            'socialsecurity' => 'text',
            'taxid' => 'text',
            'description' => 'text',
            'website' => 'url',
            'title' => 'name'
        };
        
        for (String fieldKey : fields.keySet()) {
            Schema.DescribeFieldResult fd = fields.get(fieldKey).getDescribe();
            
            // Must be updateable and accessible
            if (!fd.isUpdateable() || !fd.isAccessible()) continue;
            // Skip formula, auto-number, system fields
            if (fd.isCalculated() || fd.isAutoNumber()) continue;
            
            String apiName = fd.getName();
            String lowerName = apiName.toLowerCase();
            String category = null;
            
            // Check by field type first (EMAIL, PHONE are definitive)
            if (fd.getType() == Schema.DisplayType.EMAIL) {
                category = 'email';
            } else if (fd.getType() == Schema.DisplayType.PHONE) {
                category = 'phone';
            } else if (fd.getType() == Schema.DisplayType.URL) {
                category = 'url';
            } else {
                // Check name pattern match
                // Strip __c for custom fields
                String cleanName = lowerName.replace('__c', '');
                if (namePatterns.containsKey(cleanName)) {
                    category = namePatterns.get(cleanName);
                } else {
                    // Partial match for custom fields containing PII keywords
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

    // ---- Smart masking by PII category ----
    
    private void applySmartMask(sObject record, FieldMaskInfo info) {
        try {
            Object originalValue = record.get(info.fieldName);
            if (originalValue == null) return;
            
            Object newValue;
            
            if (info.piiCategory == 'email') {
                newValue = 'masked_' + generateRandomStr(6) + '@example.invalid';
                
            } else if (info.piiCategory == 'phone') {
                // Australian phone format: +61 4XX XXX XXX (mobile)
                String num = '+61 4' + randomDigits(2) + ' ' + randomDigits(3) + ' ' + randomDigits(3);
                newValue = num;
                
            } else if (info.piiCategory == 'name') {
                newValue = 'Masked_' + generateRandomStr(5);
                
            } else if (info.piiCategory == 'address') {
                newValue = randomDigits(3) + ' Masked Street';
                
            } else if (info.piiCategory == 'date') {
                // Random date within past 30 years
                if (info.fieldType == Schema.DisplayType.DATE) {
                    Integer daysBack = Integer.valueOf(Math.random() * 10950); // ~30 years
                    newValue = Date.today().addDays(-daysBack);
                } else if (info.fieldType == Schema.DisplayType.DATETIME) {
                    Integer daysBack = Integer.valueOf(Math.random() * 10950);
                    newValue = Datetime.now().addDays(-daysBack);
                } else {
                    newValue = 'XXXX-XX-XX';
                }
                
            } else if (info.piiCategory == 'url') {
                newValue = 'https://masked-' + generateRandomStr(5) + '.example.invalid';
                
            } else {
                // Generic text masking
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
