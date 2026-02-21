public class AttachmentMasker implements Database.Batchable<sObject>, Database.Stateful {
    
    // PII patterns for scanning text-based file content
    private static final Map<String, String> PII_PATTERNS = new Map<String, String>{
        'email' => '[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\\.[a-zA-Z]{2,}',
        'phone' => '(\\+?\\d{1,3}[-.\\s]?)?\\(?\\d{2,4}\\)?[-.\\s]?\\d{3,4}[-.\\s]?\\d{3,4}',
        'ssn' => '\\d{3}-\\d{2}-\\d{4}',
        'creditcard' => '\\d{4}[-.\\s]?\\d{4}[-.\\s]?\\d{4}[-.\\s]?\\d{4}'
    };
    
    // Text-based file extensions to scan
    private static final Set<String> TEXT_EXTENSIONS = new Set<String>{
        'txt', 'csv', 'log', 'json', 'xml', 'html', 'htm', 'md', 'rtf', 'sql'
    };
    
    // Result tracking
    private Integer filesProcessed = 0;
    private Integer filesFailed = 0;
    private List<String> errors = new List<String>();
    private Boolean maskTitles;
    private Boolean maskContent;
    
    public AttachmentMasker() {
        this.maskTitles = true;
        this.maskContent = true;
    }
    
    public AttachmentMasker(Boolean titles, Boolean content) {
        this.maskTitles = titles;
        this.maskContent = content;
    }
    
    public Database.QueryLocator start(Database.BatchableContext bc) {
        // SANDBOX GUARD
        Boolean isSandbox = [SELECT IsSandbox FROM Organization LIMIT 1].IsSandbox;
        if (!isSandbox) {
            System.debug('BLOCKED: AttachmentMasker can only run in sandbox orgs.');
            return Database.getQueryLocator('SELECT Id FROM ContentVersion WHERE Id = null');
        }
        
        return Database.getQueryLocator([
            SELECT Id, Title, FileExtension, VersionData, ContentSize 
            FROM ContentVersion 
            WHERE IsLatest = true 
            AND ContentSize < 5000000
        ]);
    }
    
    public void execute(Database.BatchableContext bc, List<ContentVersion> scope) {
        List<ContentVersion> toUpdate = new List<ContentVersion>();
        
        for (ContentVersion cv : scope) {
            try {
                Boolean changed = false;
                
                // 1. Mask file title (remove PII from filenames)
                if (maskTitles && String.isNotBlank(cv.Title)) {
                    String maskedTitle = maskPiiInText(cv.Title);
                    if (maskedTitle != cv.Title) {
                        cv.Title = maskedTitle;
                        changed = true;
                    }
                }
                
                // 2. Mask file content (text-based files only)
                if (maskContent && isTextFile(cv.FileExtension) && cv.VersionData != null) {
                    try {
                        String content = cv.VersionData.toString();
                        String maskedContent = maskPiiInText(content);
                        if (maskedContent != content) {
                            cv.VersionData = Blob.valueOf(maskedContent);
                            changed = true;
                        }
                    } catch (Exception e) {
                        // Binary file disguised as text, skip
                        if (errors.size() < 20) {
                            errors.add(cv.Id + ': Content read error - ' + e.getMessage());
                        }
                    }
                }
                
                if (changed) {
                    toUpdate.add(cv);
                }
                filesProcessed++;
            } catch (Exception e) {
                filesFailed++;
                if (errors.size() < 20) {
                    errors.add(cv.Id + ' (' + cv.Title + '): ' + e.getMessage());
                }
            }
        }
        
        if (!toUpdate.isEmpty()) {
            List<Database.SaveResult> results = Database.update(toUpdate, false);
            for (Integer i = 0; i < results.size(); i++) {
                if (!results[i].isSuccess()) {
                    filesFailed++;
                    if (errors.size() < 20) {
                        String errMsg = '';
                        for (Database.Error err : results[i].getErrors()) {
                            errMsg += err.getMessage() + '; ';
                        }
                        errors.add(toUpdate[i].Id + ': ' + errMsg);
                    }
                }
            }
        }
    }
    
    public void finish(Database.BatchableContext bc) {
        // Log results
        try {
            PII_Mask_Log__c log = new PII_Mask_Log__c();
            log.Object_Name__c = 'ContentVersion (Files)';
            log.Job_Id__c = (bc != null) ? String.valueOf(bc.getJobId()) : 'UNKNOWN';
            log.Status__c = filesFailed > 0 ? 'Partial' : 'Completed';
            log.Records_Processed__c = filesProcessed;
            log.Records_Failed__c = filesFailed;
            log.Completed_Date__c = Datetime.now();
            log.Fields_Masked__c = 'Title, VersionData';
            
            if (!errors.isEmpty()) {
                String errStr = String.join(errors, '\n');
                log.Error_Details__c = errStr.length() > 32000 ? errStr.substring(0, 32000) : errStr;
                if (filesFailed > 0 && filesProcessed == 0) {
                    log.Status__c = 'Failed';
                }
            }
            
            insert log;
        } catch (Exception e) {
            System.debug('Error creating attachment mask log: ' + e.getMessage());
        }
    }
    
    // ---- PII masking in text ----
    
    private String maskPiiInText(String text) {
        if (String.isBlank(text)) return text;
        
        String result = text;
        for (String category : PII_PATTERNS.keySet()) {
            String pattern = PII_PATTERNS.get(category);
            result = result.replaceAll(pattern, '***');
        }
        return result;
    }
    
    private Boolean isTextFile(String ext) {
        if (String.isBlank(ext)) return false;
        return TEXT_EXTENSIONS.contains(ext.toLowerCase());
    }
}
