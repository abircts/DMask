import { LightningElement, track } from 'lwc';
import getActiveJobs from '@salesforce/apex/PiiMaskingController.getActiveJobs';
import getJobHistory from '@salesforce/apex/PiiMaskingController.getJobHistory';
import getConfigs from '@salesforce/apex/PiiMaskingController.getConfigs';
import startMasking from '@salesforce/apex/PiiMaskingController.startMasking';
import getObjects from '@salesforce/apex/PiiMaskingController.getObjects';
import previewPiiFields from '@salesforce/apex/PiiMaskingController.previewPiiFields';
import addObjectConfig from '@salesforce/apex/PiiMaskingController.addObjectConfig';

const CONFIG_COLUMNS = [
    { label: 'Object', fieldName: 'objectName', type: 'text', initialWidth: 180 },
    { label: 'PII Fields', fieldName: 'fieldCount', type: 'text', initialWidth: 120 },
    { label: 'Fields Detail', fieldName: 'fields', type: 'text', wrapText: true },
    { label: 'Strategy', fieldName: 'maskingType', type: 'text', initialWidth: 100 }
];

const HISTORY_COLUMNS = [
    {
        label: 'Status', fieldName: 'status', type: 'text', initialWidth: 120,
        cellAttributes: { class: { fieldName: 'statusClass' } }
    },
    { label: 'Processed', fieldName: 'processed', type: 'number', initialWidth: 100 },
    { label: 'Total', fieldName: 'total', type: 'number', initialWidth: 100 },
    { label: 'Errors', fieldName: 'errors', type: 'number', initialWidth: 100 },
    {
        label: 'Started', fieldName: 'createdDate', type: 'date',
        typeAttributes: { year: 'numeric', month: 'short', day: '2-digit', hour: '2-digit', minute: '2-digit' }
    },
    {
        label: 'Completed', fieldName: 'completedDate', type: 'date',
        typeAttributes: { year: 'numeric', month: 'short', day: '2-digit', hour: '2-digit', minute: '2-digit' }
    }
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

    configColumns = CONFIG_COLUMNS;
    historyColumns = HISTORY_COLUMNS;
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
        this.loadConfigs();
        this.loadActiveJobs();
        this.loadJobHistory();
        this.startPolling();
    }

    disconnectedCallback() { this.stopPolling(); }

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
                    job.status === 'Failed' ? 'slds-text-color_error' : ''
            }));
        }).catch(e => console.error('Error loading job history', e));
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

    handleCancelConfig() {
        this.selectedObject = '';
        this.piiPreview = [];
        this.showConfigForm = false;
    }

    handleSaveConfig() {
        // Build comma-separated field names from current preview
        const fieldsCsv = this.piiPreview.map(f => f.fieldName).join(',');

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

    showToast(variant, message) {
        this.toastVariant = variant;
        this.toastMessage = message;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => { this.toastMessage = ''; }, 5000);
    }
}
