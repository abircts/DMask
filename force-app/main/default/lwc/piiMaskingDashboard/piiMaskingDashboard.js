import { LightningElement, track } from 'lwc';
import getActiveJobs from '@salesforce/apex/PiiMaskingController.getActiveJobs';
import getJobHistory from '@salesforce/apex/PiiMaskingController.getJobHistory';
import getConfigs from '@salesforce/apex/PiiMaskingController.getConfigs';
import startMasking from '@salesforce/apex/PiiMaskingController.startMasking';
import getObjects from '@salesforce/apex/PiiMaskingController.getObjects';
import getFields from '@salesforce/apex/PiiMaskingController.getFields';
import saveConfig from '@salesforce/apex/PiiMaskingController.saveConfig';

const CONFIG_COLUMNS = [
    { label: 'Object', fieldName: 'objectName', type: 'text', initialWidth: 150 },
    { label: 'Field', fieldName: 'fieldName', type: 'text', initialWidth: 150 },
    { label: 'Masking Type', fieldName: 'maskingType', type: 'text', initialWidth: 130 },
    { label: 'Pattern', fieldName: 'pattern', type: 'text' }
];

const HISTORY_COLUMNS = [
    {
        label: 'Status', fieldName: 'status', type: 'text', initialWidth: 120,
        cellAttributes: {
            class: { fieldName: 'statusClass' }
        }
    },
    { label: 'Processed', fieldName: 'processed', type: 'number', initialWidth: 100 },
    { label: 'Total', fieldName: 'total', type: 'number', initialWidth: 100 },
    { label: 'Errors', fieldName: 'errors', type: 'number', initialWidth: 100 },
    {
        label: 'Started', fieldName: 'createdDate', type: 'date',
        typeAttributes: {
            year: 'numeric', month: 'short', day: '2-digit',
            hour: '2-digit', minute: '2-digit'
        }
    },
    {
        label: 'Completed', fieldName: 'completedDate', type: 'date',
        typeAttributes: {
            year: 'numeric', month: 'short', day: '2-digit',
            hour: '2-digit', minute: '2-digit'
        }
    }
];

const MASKING_TYPE_OPTIONS = [
    { label: 'Static — Replace with fixed value', value: 'Static' },
    { label: 'Suffix — Append to original value', value: 'Suffix' },
    { label: 'Random — Replace with random string', value: 'Random' }
];

const POLL_INTERVAL = 5000;

export default class PiiMaskingDashboard extends LightningElement {
    @track activeJobs = [];
    @track jobHistory = [];
    @track configs = [];
    @track isRunning = false;
    @track toastMessage = '';
    @track toastVariant = 'success';

    // Config form state
    @track showConfigForm = false;
    @track objectOptions = [];
    @track fieldOptions = [];
    @track selectedObject = '';
    @track selectedField = '';
    @track selectedMaskingType = '';
    @track configPattern = '';
    @track isLoadingFields = false;

    configColumns = CONFIG_COLUMNS;
    historyColumns = HISTORY_COLUMNS;
    maskingTypeOptions = MASKING_TYPE_OPTIONS;
    _pollTimer;

    get hasActiveJobs() {
        return this.activeJobs && this.activeJobs.length > 0;
    }

    get hasConfigs() {
        return this.configs && this.configs.length > 0;
    }

    get hasHistory() {
        return this.jobHistory && this.jobHistory.length > 0;
    }

    get toastClass() {
        return `toast-bar toast-${this.toastVariant}`;
    }

    get toastIcon() {
        return this.toastVariant === 'success' ? 'utility:success' : 'utility:error';
    }

    get configFormChevron() {
        return this.showConfigForm ? 'utility:chevrondown' : 'utility:chevronright';
    }

    get isFieldDisabled() {
        return !this.selectedObject || this.isLoadingFields;
    }

    get isSaveDisabled() {
        return !this.selectedObject || !this.selectedField || !this.selectedMaskingType;
    }

    connectedCallback() {
        this.loadConfigs();
        this.loadActiveJobs();
        this.loadJobHistory();
        this.startPolling();
    }

    disconnectedCallback() {
        this.stopPolling();
    }

    startPolling() {
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this._pollTimer = setInterval(() => {
            this.loadActiveJobs();
            this.loadJobHistory();
        }, POLL_INTERVAL);
    }

    stopPolling() {
        if (this._pollTimer) {
            clearInterval(this._pollTimer);
        }
    }

    loadConfigs() {
        getConfigs()
            .then(result => {
                this.configs = result;
            })
            .catch(error => {
                console.error('Error loading configs', error);
            });
    }

    loadActiveJobs() {
        getActiveJobs()
            .then(result => {
                this.activeJobs = result;
                this.isRunning = result && result.length > 0;
            })
            .catch(error => {
                console.error('Error loading active jobs', error);
            });
    }

    loadJobHistory() {
        getJobHistory()
            .then(result => {
                this.jobHistory = result.map(job => ({
                    ...job,
                    statusClass: this.getStatusClass(job.status)
                }));
            })
            .catch(error => {
                console.error('Error loading job history', error);
            });
    }

    getStatusClass(status) {
        if (status === 'Completed') return 'slds-text-color_success';
        if (status === 'Failed') return 'slds-text-color_error';
        return '';
    }

    handleStartMasking() {
        this.isRunning = true;
        startMasking()
            .then(jobId => {
                if (jobId) {
                    this.showToast('success', 'Masking job started successfully! Job ID: ' + jobId);
                    this.loadActiveJobs();
                } else {
                    this.showToast('error', 'No PII configurations found. Add records to PII Mask Config first.');
                    this.isRunning = false;
                }
            })
            .catch(error => {
                this.showToast('error', 'Error starting masking: ' + (error.body ? error.body.message : error.message));
                this.isRunning = false;
            });
    }

    // ---- Config Form Methods ----

    toggleConfigForm() {
        this.showConfigForm = !this.showConfigForm;
        if (this.showConfigForm && this.objectOptions.length === 0) {
            this.loadObjects();
        }
    }

    loadObjects() {
        getObjects()
            .then(result => {
                this.objectOptions = result;
            })
            .catch(error => {
                console.error('Error loading objects', error);
                this.showToast('error', 'Error loading objects: ' + (error.body ? error.body.message : error.message));
            });
    }

    handleObjectChange(event) {
        this.selectedObject = event.detail.value;
        this.selectedField = '';
        this.fieldOptions = [];
        this.isLoadingFields = true;

        getFields({ objectName: this.selectedObject })
            .then(result => {
                this.fieldOptions = result;
                this.isLoadingFields = false;
            })
            .catch(error => {
                console.error('Error loading fields', error);
                this.isLoadingFields = false;
                this.showToast('error', 'Error loading fields: ' + (error.body ? error.body.message : error.message));
            });
    }

    handleFieldChange(event) {
        this.selectedField = event.detail.value;
    }

    handleMaskingTypeChange(event) {
        this.selectedMaskingType = event.detail.value;
    }

    handlePatternChange(event) {
        this.configPattern = event.detail.value;
    }

    handleCancelConfig() {
        this.resetConfigForm();
        this.showConfigForm = false;
    }

    handleSaveConfig() {
        saveConfig({
            objectName: this.selectedObject,
            fieldName: this.selectedField,
            maskingType: this.selectedMaskingType,
            pattern: this.configPattern
        })
            .then(message => {
                this.showToast('success', message);
                this.resetConfigForm();
                // Refresh configs after a short delay (metadata deployment is async)
                // eslint-disable-next-line @lwc/lwc/no-async-operation
                setTimeout(() => {
                    this.loadConfigs();
                }, 5000);
            })
            .catch(error => {
                this.showToast('error', 'Error saving config: ' + (error.body ? error.body.message : error.message));
            });
    }

    resetConfigForm() {
        this.selectedObject = '';
        this.selectedField = '';
        this.selectedMaskingType = '';
        this.configPattern = '';
        this.fieldOptions = [];
    }

    showToast(variant, message) {
        this.toastVariant = variant;
        this.toastMessage = message;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            this.toastMessage = '';
        }, 5000);
    }
}
