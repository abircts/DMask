import { LightningElement, track } from 'lwc';
import getActiveJobs from '@salesforce/apex/PiiMaskingController.getActiveJobs';
import getJobHistory from '@salesforce/apex/PiiMaskingController.getJobHistory';
import getConfigs from '@salesforce/apex/PiiMaskingController.getConfigs';
import startMasking from '@salesforce/apex/PiiMaskingController.startMasking';
import getObjects from '@salesforce/apex/PiiMaskingController.getObjects';
import previewPiiFields from '@salesforce/apex/PiiMaskingController.previewPiiFields';
import addObjectConfig from '@salesforce/apex/PiiMaskingController.addObjectConfig';
import removeConfig from '@salesforce/apex/PiiMaskingController.removeConfig';
import retryFailed from '@salesforce/apex/PiiMaskingController.retryFailed';
import getOrgInfo from '@salesforce/apex/PiiMaskingController.getOrgInfo';
import previewMasking from '@salesforce/apex/PiiMaskingController.previewMasking';
import startFileMasking from '@salesforce/apex/PiiMaskingController.startFileMasking';

const CONFIG_COLUMNS = [
    { label: 'Object', fieldName: 'objectName', type: 'text', initialWidth: 180 },
    { label: 'PII Fields', fieldName: 'fieldCount', type: 'text', initialWidth: 120 },
    { label: 'Fields Detail', fieldName: 'fields', type: 'text', wrapText: true },
    { label: 'Strategy', fieldName: 'maskingType', type: 'text', initialWidth: 100 },
    {
        type: 'action',
        typeAttributes: {
            rowActions: [{ label: 'Remove', name: 'remove', iconName: 'utility:delete' }]
        }
    }
];

const HISTORY_COLUMNS = [
    { label: 'Object', fieldName: 'objectName', type: 'text', initialWidth: 140 },
    {
        label: 'Status', fieldName: 'status', type: 'text', initialWidth: 100,
        cellAttributes: { class: { fieldName: 'statusClass' } }
    },
    { label: 'Processed', fieldName: 'recordsProcessed', type: 'number', initialWidth: 100 },
    { label: 'Failed', fieldName: 'recordsFailed', type: 'number', initialWidth: 80 },
    { label: 'Fields Masked', fieldName: 'fieldsMasked', type: 'text', wrapText: true },
    {
        label: 'Completed', fieldName: 'completedDate', type: 'date',
        typeAttributes: { year: 'numeric', month: 'short', day: '2-digit', hour: '2-digit', minute: '2-digit' }
    },
    {
        type: 'action',
        typeAttributes: {
            rowActions: [{ label: 'Retry Failed', name: 'retry', iconName: 'utility:refresh' }]
        }
    }
];

const MASKING_OPTIONS = [
    { label: 'Auto (Smart)', value: 'auto' },
    { label: 'Static (***MASKED***)', value: 'Static' },
    { label: 'Random String', value: 'Random' },
    { label: 'Suffix (ab***)', value: 'Suffix' },
    { label: '📧 Email', value: 'email' },
    { label: '📞 AU Phone', value: 'phone' },
    { label: '👤 Name', value: 'name' },
    { label: '📍 Address', value: 'address' },
    { label: '📅 Date', value: 'date' },
    { label: '🔗 URL', value: 'url' },
    { label: '🔤 Text', value: 'text' },
    { label: '🔧 Regex (Custom)', value: 'Regex' }
];

const CATEGORY_LABELS = {
    email: '📧 Email → masked_xxx@example.invalid',
    phone: '📞 Phone → +61 4XX XXX XXX',
    name: '👤 Name → Masked_xxxxx',
    address: '📍 Address → 123 Masked Street',
    date: '📅 Date → Random date',
    url: '🔗 URL → masked-xxx.example.invalid',
    text: '🔤 Text → MASKED_xxxxxxxx'
};

const CATEGORY_BADGES = {
    email: 'badge-email',
    phone: 'badge-phone',
    name: 'badge-name',
    address: 'badge-address',
    date: 'badge-date',
    url: 'badge-url',
    text: 'badge-text'
};

const POLL_INTERVAL = 5000;

export default class PiiMaskingDashboard extends LightningElement {
    @track activeJobs = [];
    @track jobHistory = [];
    @track configs = [];
    @track isRunning = false;
    @track toastMessage = '';
    @track toastVariant = 'success';

    // Config form
    @track showConfigForm = false;
    @track objectOptions = [];
    @track selectedObject = '';
    @track piiPreview = [];
    @track isLoadingPreview = false;

    // Run modal
    @track showRunModal = false;
    @track runModalItems = [];

    // Org info (sandbox guard)
    @track orgInfo = {};
    get isSandboxOrg() { return this.orgInfo && this.orgInfo.isSandbox === true; }
    get orgBadgeLabel() {
        if (!this.orgInfo) return '';
        return this.orgInfo.isSandbox ? '🟢 Sandbox' : '🔴 Production';
    }
    get orgBadgeClass() {
        return this.orgInfo && this.orgInfo.isSandbox ? 'slds-badge slds-badge_inverse' : 'slds-badge slds-theme_error';
    }

    // Preview / Dry Run
    @track previewData = [];
    @track showPreviewModal = false;
    @track previewObjectName = '';
    @track isLoadingDryRun = false;
    get hasPreviewData() { return this.previewData && this.previewData.length > 0; }

    configColumns = CONFIG_COLUMNS;
    historyColumns = HISTORY_COLUMNS;
    maskingOptions = MASKING_OPTIONS;
    _pollTimer;

    get hasActiveJobs() { return this.activeJobs && this.activeJobs.length > 0; }
    get hasConfigs() { return this.configs && this.configs.length > 0; }
    get hasHistory() { return this.jobHistory && this.jobHistory.length > 0; }
    get hasPiiPreview() { return this.piiPreview && this.piiPreview.length > 0 && this.selectedObject; }
    get noPiiFound() { return this.selectedObject && !this.isLoadingPreview && this.piiPreview.length === 0; }
    get piiPreviewCount() { return this.piiPreview ? this.piiPreview.length : 0; }
    get isSaveDisabled() { return !this.selectedObject || this.piiPreview.length === 0; }
    get configFormChevron() { return this.showConfigForm ? 'utility:chevrondown' : 'utility:chevronright'; }
    get toastClass() { return `toast-bar toast-${this.toastVariant}`; }
    get toastIcon() { return this.toastVariant === 'success' ? 'utility:success' : 'utility:error'; }
    get allSelected() { return this.runModalItems.length > 0 && this.runModalItems.every(i => i.selected); }
    get selectedRunCount() { return this.runModalItems.filter(i => i.selected).length; }
    get isRunDisabled() { return this.selectedRunCount === 0; }
    get runButtonLabel() {
        const cnt = this.selectedRunCount;
        return cnt === this.runModalItems.length ? `Run All (${cnt})` : `Run Selected (${cnt})`;
    }

    connectedCallback() {
        this.loadOrgInfo();
        this.loadConfigs();
        this.loadActiveJobs();
        this.loadJobHistory();
        this.startPolling();
    }

    disconnectedCallback() { this.stopPolling(); }

    loadOrgInfo() {
        getOrgInfo()
            .then(result => { this.orgInfo = result; })
            .catch(e => console.error('Error loading org info', e));
    }

    startPolling() {
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._pollTimer = setInterval(() => {
            this.loadActiveJobs();
            this.loadJobHistory();
        }, POLL_INTERVAL);
    }

    stopPolling() { if (this._pollTimer) clearInterval(this._pollTimer); }

    loadConfigs() {
        getConfigs().then(result => { this.configs = result; })
            .catch(e => console.error('Error loading configs', e));
    }

    handleConfigAction(event) {
        const action = event.detail.action.name;
        const row = event.detail.row;
        if (action === 'remove') {
            removeConfig({ devName: row.id })
                .then(msg => {
                    this.showToast('success', msg);
                    // Remove from local list immediately
                    this.configs = this.configs.filter(c => c.id !== row.id);
                    // Refresh from server after deploy completes
                    // eslint-disable-next-line @lwc/lwc/no-async-operation
                    setTimeout(() => this.loadConfigs(), 5000);
                })
                .catch(e => {
                    this.showToast('error', 'Error: ' + (e.body ? e.body.message : e.message));
                });
        }
    }

    loadActiveJobs() {
        getActiveJobs().then(result => {
            this.activeJobs = result;
            this.isRunning = result && result.length > 0;
        }).catch(e => console.error('Error loading active jobs', e));
    }

    loadJobHistory() {
        getJobHistory().then(result => {
            this.jobHistory = result.map(job => ({
                ...job,
                statusClass: job.status === 'Completed' ? 'slds-text-color_success' :
                    (job.status === 'Failed' || job.status === 'Partial') ? 'slds-text-color_error' : ''
            }));
        }).catch(e => console.error('Error loading job history', e));
    }

    handleHistoryAction(event) {
        const action = event.detail.action.name;
        const row = event.detail.row;
        if (action === 'retry') {
            if (!row.hasFailures) {
                this.showToast('info', 'No failed records to retry for this log entry.');
                return;
            }
            retryFailed({ logName: row.id })
                .then(jobId => {
                    if (jobId) {
                        this.showToast('success', 'Retry started for ' + row.objectName + '! Job ID: ' + jobId);
                        this.loadActiveJobs();
                    }
                })
                .catch(e => {
                    this.showToast('error', 'Retry error: ' + (e.body ? e.body.message : e.message));
                });
        }
    }

    handleStartMasking() {
        // Open modal with configured objects
        this.loadConfigs();
        this.runModalItems = this.configs.map(c => ({
            objectName: c.objectName,
            label: c.objectName,
            fieldCount: c.fieldCount || 'Auto-detect',
            selected: true
        }));
        this.showRunModal = true;
    }

    handleCloseRunModal() {
        this.showRunModal = false;
    }

    handleSelectAll(event) {
        const checked = event.target.checked;
        this.runModalItems = this.runModalItems.map(i => ({ ...i, selected: checked }));
    }

    handleToggleRunItem(event) {
        const objName = event.currentTarget.dataset.obj;
        this.runModalItems = this.runModalItems.map(i =>
            i.objectName === objName ? { ...i, selected: event.target.checked } : i
        );
    }

    handleConfirmRun() {
        const selectedObjects = this.runModalItems
            .filter(i => i.selected)
            .map(i => i.objectName);

        if (selectedObjects.length === 0) {
            this.showToast('error', 'Please select at least one object.');
            return;
        }

        this.showRunModal = false;
        this.isRunning = true;

        startMasking({ selectedObjects: selectedObjects })
            .then(jobId => {
                if (jobId) {
                    this.showToast('success', 'Masking started for ' + selectedObjects.join(', ') + '! Job ID: ' + jobId);
                    this.loadActiveJobs();
                } else {
                    this.showToast('error', 'Failed to start masking.');
                    this.isRunning = false;
                }
            })
            .catch(error => {
                this.showToast('error', 'Error: ' + (error.body ? error.body.message : error.message));
                this.isRunning = false;
            });
    }

    // ---- Config Form ----

    toggleConfigForm() {
        this.showConfigForm = !this.showConfigForm;
        if (this.showConfigForm && this.objectOptions.length === 0) {
            getObjects().then(result => { this.objectOptions = result; })
                .catch(e => this.showToast('error', 'Error loading objects: ' + (e.body ? e.body.message : e.message)));
        }
    }

    handleObjectChange(event) {
        this.selectedObject = event.detail.value;
        this.piiPreview = [];
        this.isLoadingPreview = true;

        previewPiiFields({ objectName: this.selectedObject })
            .then(result => {
                this.piiPreview = result.map(field => ({
                    ...field,
                    selectedMask: 'auto',
                    maskLabel: CATEGORY_LABELS[field.category] || field.category,
                    badgeClass: 'pii-badge ' + (CATEGORY_BADGES[field.category] || '')
                }));
                this.isLoadingPreview = false;
            })
            .catch(e => {
                console.error('Error previewing PII fields', e);
                this.isLoadingPreview = false;
            });
    }

    handleRemoveField(event) {
        const fieldToRemove = event.currentTarget.dataset.field;
        this.piiPreview = this.piiPreview.filter(f => f.fieldName !== fieldToRemove);
    }

    handleMaskChange(event) {
        const fieldName = event.currentTarget.dataset.field;
        const newMask = event.detail.value;
        this.piiPreview = this.piiPreview.map(f =>
            f.fieldName === fieldName ? { ...f, selectedMask: newMask, showRegex: newMask === 'Regex' } : f
        );
    }

    handleCancelConfig() {
        this.selectedObject = '';
        this.piiPreview = [];
        this.showConfigForm = false;
    }

    handleSaveConfig() {
        // Build field:maskType CSV — support Regex:pattern format
        const fieldsCsv = this.piiPreview.map(f => {
            const mask = f.selectedMask || 'auto';
            if (mask === 'auto') return f.fieldName;
            if (mask === 'Regex' && f.regexPattern) {
                return `${f.fieldName}:Regex:${f.regexPattern}`;
            }
            return `${f.fieldName}:${mask}`;
        }).join(',');

        addObjectConfig({ objectName: this.selectedObject, fieldsCsv: fieldsCsv })
            .then(message => {
                this.showToast('success', message);
                this.selectedObject = '';
                this.piiPreview = [];
                // eslint-disable-next-line @lwc/lwc/no-async-operation
                setTimeout(() => this.loadConfigs(), 5000);
            })
            .catch(e => {
                this.showToast('error', 'Error: ' + (e.body ? e.body.message : e.message));
            });
    }

    // ---- Preview / Dry Run ----

    handlePreviewMasking() {
        this.previewData = [];
        this.previewObjectName = '';
        this.showPreviewModal = true;
        if (this.objectOptions.length === 0) {
            getObjects().then(result => { this.objectOptions = result; })
                .catch(e => this.showToast('error', 'Error loading objects: ' + (e.body ? e.body.message : e.message)));
        }
    }

    handlePreviewObjectSelect(event) {
        this.previewObjectName = event.detail.value;
        this.isLoadingDryRun = true;
        this.previewData = [];

        previewMasking({ objectName: this.previewObjectName })
            .then(result => {
                this.previewData = result.map((r, idx) => ({
                    key: idx,
                    recordId: r.recordId,
                    fieldName: r.fieldName,
                    category: r.category,
                    originalValue: r.originalValue,
                    maskedValue: r.maskedValue
                }));
                this.isLoadingDryRun = false;
            })
            .catch(e => {
                this.showToast('error', 'Preview error: ' + (e.body ? e.body.message : e.message));
                this.isLoadingDryRun = false;
            });
    }

    handleClosePreviewModal() {
        this.showPreviewModal = false;
    }

    // ---- File/Attachment Masking ----

    handleStartFileMasking() {
        startFileMasking()
            .then(jobId => {
                if (jobId) {
                    this.showToast('success', 'File masking started! Job ID: ' + jobId);
                    this.loadActiveJobs();
                }
            })
            .catch(e => {
                this.showToast('error', 'Error: ' + (e.body ? e.body.message : e.message));
            });
    }

    // ---- Regex Pattern ----

    handleRegexChange(event) {
        const fieldName = event.currentTarget.dataset.field;
        const pattern = event.detail.value;
        this.piiPreview = this.piiPreview.map(f =>
            f.fieldName === fieldName ? { ...f, regexPattern: pattern } : f
        );
    }

    downloadCsv() {
        if (!this.jobHistory || this.jobHistory.length === 0) return;
        const headers = ['Log#', 'Object', 'Status', 'Records Processed', 'Records Failed', 'Fields Masked', 'Error Details', 'Completed Date'];
        const rows = this.jobHistory.map(j => [
            j.id || '',
            j.objectName || '',
            j.status || '',
            j.recordsProcessed || 0,
            j.recordsFailed || 0,
            `"${(j.fieldsMasked || '').replace(/"/g, '""')}"`,
            `"${(j.errorDetails || '').replace(/"/g, '""')}"`,
            j.completedDate || ''
        ]);
        const csv = [headers.join(','), ...rows.map(r => r.join(','))].join('\n');
        // Use data URI instead of Blob to avoid Locker Service MIME type error
        const encodedCsv = encodeURIComponent(csv);
        const a = document.createElement('a');
        a.href = 'data:text/csv;charset=utf-8,' + encodedCsv;
        a.download = `pii_masking_history_${new Date().toISOString().slice(0, 10)}.csv`;
        document.body.appendChild(a);
        a.click();
        document.body.removeChild(a);
    }

    showToast(variant, message) {
        this.toastVariant = variant;
        this.toastMessage = message;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => { this.toastMessage = ''; }, 5000);
    }
}
