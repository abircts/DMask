import { LightningElement, track } from 'lwc';
import getActiveJobs from '@salesforce/apex/PiiMaskingController.getActiveJobs';
import getJobHistory from '@salesforce/apex/PiiMaskingController.getJobHistory';
import getConfigs from '@salesforce/apex/PiiMaskingController.getConfigs';
import startMasking from '@salesforce/apex/PiiMaskingController.startMasking';

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

const POLL_INTERVAL = 5000;

export default class PiiMaskingDashboard extends LightningElement {
    @track activeJobs = [];
    @track jobHistory = [];
    @track configs = [];
    @track isRunning = false;
    @track toastMessage = '';
    @track toastVariant = 'success';

    configColumns = CONFIG_COLUMNS;
    historyColumns = HISTORY_COLUMNS;
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

    showToast(variant, message) {
        this.toastVariant = variant;
        this.toastMessage = message;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            this.toastMessage = '';
        }, 5000);
    }
}
