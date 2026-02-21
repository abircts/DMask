/**
 * Centralized PII field detection, input validation, and shared patterns.
 * Used by SandboxDataMasker, AttachmentMasker, and PiiMaskingController.
 */
public inherited sharing class PiiFieldDetector {
    
    // ---- Cached describes to avoid repeated expensive calls ----
    
    private static Map<String, Schema.SObjectType> cachedGlobalDescribe;
    private static Boolean cachedIsSandbox;
    
    public static Map<String, Schema.SObjectType> getGlobalDescribe() {
        if (cachedGlobalDescribe == null) {
            cachedGlobalDescribe = Schema.getGlobalDescribe();
        }
        return cachedGlobalDescribe;
    }
    
    public static Boolean isSandbox() {
        if (cachedIsSandbox == null) {
            cachedIsSandbox = [SELECT IsSandbox FROM Organization LIMIT 1].IsSandbox;
        }
        return cachedIsSandbox;
    }
    
    // ---- Input validation (prevents SOQL injection) ----
    
    /**
     * Validates that the object name exists in the org schema.
     * Throws AuraHandledException if invalid.
     */
    public static String validateObjectName(String objectName) {
        if (String.isBlank(objectName)) {
            throw new AuraHandledException('Object name cannot be blank.');
        }
        String cleaned = objectName.trim();
        if (!getGlobalDescribe().containsKey(cleaned.toLowerCase())) {
            throw new AuraHandledException('Invalid object: ' + cleaned);
        }
        // Return the canonical API name from the schema
        return getGlobalDescribe().get(cleaned.toLowerCase()).getDescribe().getName();
    }
    
    /**
     * Validates that each field name exists and is accessible on the given object.
     * Returns only the valid, safe field names.
     */
    public static Set<String> validateFieldNames(String objectName, Set<String> fieldNames) {
        Schema.SObjectType objType = getGlobalDescribe().get(objectName.toLowerCase());
        if (objType == null) return new Set<String>();
        
        Map<String, Schema.SObjectField> fieldMap = objType.getDescribe().fields.getMap();
        Set<String> validated = new Set<String>();
        
        for (String fName : fieldNames) {
            String lower = fName.trim().toLowerCase();
            if (fieldMap.containsKey(lower)) {
                // Use canonical API name from schema
                validated.add(fieldMap.get(lower).getDescribe().getName());
            }
        }
        return validated;
    }
    
    // ---- Shared PII regex patterns (used by both SandboxDataMasker and AttachmentMasker) ----
    
    public static final Map<String, String> PII_CONTENT_PATTERNS = new Map<String, String>{
        'email' => '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}',
        'phone' => '(\\+?\\d{1,3}[-.\\s]?)?\\(?\\d{2,4}\\)?[-.\\s]?\\d{3,4}[-.\\s]?\\d{3,4}',
        'ssn' => '\\d{3}-\\d{2}-\\d{4}',
        'creditcard' => '\\d{4}[-.\\s]?\\d{4}[-.\\s]?\\d{4}[-.\\s]?\\d{4}'
    };
    
    // Text-based file extensions to scan
    public static final Set<String> TEXT_FILE_EXTENSIONS = new Set<String>{
        'txt', 'csv', 'log', 'json', 'xml', 'html', 'htm', 'md', 'rtf', 'sql'
    };
    
    // ---- PII field name patterns (for auto-detection by field name) ----
    
    public static final Map<String, String> FIELD_NAME_PATTERNS = new Map<String, String>{
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
    
    /**
     * Auto-detect PII fields on a given SObject by analyzing field names and types.
     * Uses cached schema describes.
     */
    public static List<SandboxDataMasker.FieldMaskInfo> detectPiiFields(String objectName) {
        List<SandboxDataMasker.FieldMaskInfo> result = new List<SandboxDataMasker.FieldMaskInfo>();
        
        Schema.SObjectType objType = getGlobalDescribe().get(objectName.toLowerCase());
        if (objType == null) return result;
        
        Map<String, Schema.SObjectField> fields = objType.getDescribe().fields.getMap();
        
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
                if (FIELD_NAME_PATTERNS.containsKey(cleanName)) {
                    category = FIELD_NAME_PATTERNS.get(cleanName);
                } else {
                    for (String pattern : FIELD_NAME_PATTERNS.keySet()) {
                        if (cleanName.contains(pattern)) {
                            category = FIELD_NAME_PATTERNS.get(pattern);
                            break;
                        }
                    }
                }
            }
            
            if (category != null) {
                result.add(new SandboxDataMasker.FieldMaskInfo(apiName, fd.getType(), category));
            }
        }
        
        return result;
    }
    
    /**
     * Mask PII patterns in text content. Used by AttachmentMasker and content scanning.
     */
    public static String maskPiiInText(String text) {
        if (String.isBlank(text)) return text;
        
        String result = text;
        for (String category : PII_CONTENT_PATTERNS.keySet()) {
            String pattern = PII_CONTENT_PATTERNS.get(category);
            result = result.replaceAll(pattern, '***');
        }
        return result;
    }
    
    /**
     * Check if a file extension is text-based (safe to scan for PII).
     */
    public static Boolean isTextFile(String ext) {
        if (String.isBlank(ext)) return false;
        return TEXT_FILE_EXTENSIONS.contains(ext.toLowerCase());
    }
    
    /**
     * Build a safe, validated SOQL query for PII fields on an object.
     */
    public static String buildSafeQuery(String objectName, List<SandboxDataMasker.FieldMaskInfo> fieldsToMask) {
        // Validate object
        String validatedObj = validateObjectName(objectName);
        
        // Validate fields
        Set<String> requestedFields = new Set<String>{'Id'};
        for (SandboxDataMasker.FieldMaskInfo info : fieldsToMask) {
            requestedFields.add(info.fieldName);
        }
        Set<String> validFields = validateFieldNames(validatedObj, requestedFields);
        if (!validFields.contains('Id')) validFields.add('Id');
        
        return 'SELECT ' + String.join(new List<String>(validFields), ',') + ' FROM ' + validatedObj;
    }
}
