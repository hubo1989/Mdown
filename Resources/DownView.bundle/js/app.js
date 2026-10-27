/**
 * Mdown App Main Entry
 */

class MdownApp {
  constructor() {
    this.initialize();
  }

  initialize() {
    // Use common module for interactive checkboxes
    if (window.MdownCommon) {
      MdownCommon.setupInteractiveCheckboxes();
      MdownCommon.setupDiagramExport();
    }
  }
}

MdownCommon.onDOMReady(() => {
  new MdownApp();
});

window.MdownApp = MdownApp;
