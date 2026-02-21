/**
 * Batch class that masks PII in file titles and text-based file content.
 * Delegates to PiiFieldDetector for shared PII patterns and text file detection.
 * Intentionally 'without sharing' for system-level file access.
 */
public without sharing class AttachmentMasker implements Database.Batchable<sObject>, Database.Stateful {
    
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
        // SANDBOX GUARD (cached)
        if (!PiiFieldDetector.isSandbox()) {
            System.debug('BLOCKED: AttachmentMasker can only run in sandbox orgs.');
            return Database.getQueryLocator('SELECT Id FROM ContentVersion WHERE Id = null');
        }
        
        // Build text-extension filter to avoid loading binary file bodies into heap
        List<String> extFilters = new List<String>();
        for (String ext : PiiFieldDetector.TEXT_FILE_EXTENSIONS) {
            extFilters.add('\'' + String.escapeSingleQuotes(ext) + '\'');
        }
        String extClause = String.join(extFilters, ',');
        
        String query = 'SELECT Id, Title, FileExtension, VersionData, ContentSize '
            + 'FROM ContentVersion '
            + 'WHERE IsLatest = true '
            + 'AND ContentSize < 5000000';
        
        // Only load VersionData for text-based files (performance: avoids loading binary blobs)
        if (maskContent) {
            query += ' AND (FileExtension IN (' + extClause + ') OR FileExtension = null)';
        }
        
        return Database.getQueryLocator(query);
    }
    
    public void execute(Database.BatchableContext bc, List<ContentVersion> scope) {
        List<ContentVersion> toUpdate = new List<ContentVersion>();
        
        for (ContentVersion cv : scope) {
            try {
                Boolean changed = false;
                
                // 1. Mask file title (remove PII from filenames)
                if (maskTitles && String.isNotBlank(cv.Title)) {
                    String maskedTitle = PiiFieldDetector.maskPiiInText(cv.Title);
                    if (maskedTitle != cv.Title) {
                        cv.Title = maskedTitle;
                        changed = true;
                    }
                }
                
                // 2. Mask file content (text-based files only)
                if (maskContent && PiiFieldDetector.isTextFile(cv.FileExtension) && cv.VersionData != null) {
                    try {
                        String content = cv.VersionData.toString();
                        String maskedContent = PiiFieldDetector.maskPiiInText(content);
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
}
