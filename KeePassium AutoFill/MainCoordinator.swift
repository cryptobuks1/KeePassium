//  KeePassium Password Manager
//  Copyright © 2018 Andrei Popleteev <info@keepassium.com>
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.

import UIKit
import KeePassiumLib
import AuthenticationServices
import LocalAuthentication

class MainCoordinator: NSObject, Coordinator {
    unowned var rootController: CredentialProviderViewController
    var childCoordinators = [Coordinator]()
    var navigationController: UINavigationController
    
    var serviceIdentifiers = [ASCredentialServiceIdentifier]()
    fileprivate var databaseManagerNotifications: DatabaseManagerNotifications?
    fileprivate var isLoadingUsingStoredDatabaseKey = false
    
    fileprivate weak var addDatabasePicker: UIDocumentPickerViewController?
    fileprivate weak var addKeyFilePicker: UIDocumentPickerViewController?
    
    fileprivate var watchdog: Watchdog
    fileprivate var passcodeInputController: PasscodeInputVC?
    fileprivate var isBiometricAuthShown = false
    fileprivate var isPasscodeInputShown = false
    fileprivate var isStarted = false
    
    init(rootController: CredentialProviderViewController) {
        self.rootController = rootController
        navigationController = UINavigationController()
        navigationController.view.backgroundColor = .clear
        watchdog = Watchdog.shared // init
        super.init()

        navigationController.delegate = self
        watchdog.delegate = self
    }
    
    func start() {
        databaseManagerNotifications = DatabaseManagerNotifications(observer: self)
        databaseManagerNotifications?.startObserving()
        watchdog.didBecomeActive()
        if !isAppLockVisible {
            rootController.present(navigationController, animated: false, completion: nil)
        }
        startMainFlow()
    }

    fileprivate func startMainFlow() {
        showDatabaseChooser() { [weak self] in
            self?.isStarted = true
        }
    }
    
    // Clears and closes any resources before quitting the extension.
    func cleanup() {
        databaseManagerNotifications?.stopObserving()
        DatabaseManager.shared.closeDatabase(clearStoredKey: false)
    }

    /// Closes all view controllers and quits the extension.
    func dismissAndQuit() {
        rootController.dismiss()
        cleanup()
    }

    /// Provides entry's details to the authentication services
    /// and quits the extension.
    func returnCredentials(entry: Entry) {
        watchdog.restart()
        let passwordCredential = ASPasswordCredential(user: entry.userName, password: entry.password)
        rootController.extensionContext.completeRequest(
            withSelectedCredential: passwordCredential,
            completionHandler: nil)
        cleanup()
    }
    
    /// If the visible VC contains a list of files - refreshes it.
    private func refreshFileList() {
        guard let topVC = navigationController.topViewController else { return }
        (topVC as? DatabaseChooserVC)?.refresh()
        (topVC as? KeyFileChooserVC)?.refresh()
    }
    
    private func tryToUnlockDatabase(
        database: URLReference,
        password: String,
        keyFile: URLReference?)
    {
        isLoadingUsingStoredDatabaseKey = false
        DatabaseManager.shared.startLoadingDatabase(
            database: database,
            password: password,
            keyFile: keyFile)
    }
    
    private func tryToUnlockDatabase(
        database: URLReference,
        compositeKey: SecureByteArray)
    {
        isLoadingUsingStoredDatabaseKey = true
        DatabaseManager.shared.startLoadingDatabase(
            database: database,
            compositeKey: compositeKey)
    }
    
    // MARK: - Actions
    
    func showDatabaseChooser(completion: (()->Void)?) {
        let databaseChooserVC = DatabaseChooserVC.instantiateFromStoryboard()
        databaseChooserVC.delegate = self
        navigationController.pushViewController(databaseChooserVC, animated: false)
        
        let allRefs = FileKeeper.shared.getAllReferences(fileType: .database, includeBackup: false)
        if allRefs.isEmpty {
            let firstSetupVC = FirstSetupVC.make(coordinator: self)
            firstSetupVC.navigationItem.hidesBackButton = true
            navigationController.pushViewController(firstSetupVC, animated: false)
            completion?()
        } else if allRefs.count == 1 {
            // If only one database, open it straight away
            showDatabaseUnlocker(database: allRefs.first!, animated: false, completion: completion)
        }
    }
    
    func addDatabase() {
        let picker = UIDocumentPickerViewController(
            documentTypes: FileType.publicDataUTIs,
            in: .open)
        picker.delegate = self
        navigationController.topViewController?.present(picker, animated: true, completion: nil)
        
        // remember the instance to recognize it in delegate method
        addDatabasePicker = picker
    }
    
    func removeDatabase(_ urlRef: URLReference) {
        //TODO: ask for confirmation
        FileKeeper.shared.removeExternalReference(urlRef, fileType: .database)
        try? Keychain.shared.removeDatabaseKey(databaseRef: urlRef)
        refreshFileList()
    }
    
    func showDatabaseFileInfo(fileRef: URLReference) {
        let databaseInfoVC = FileInfoVC.make(urlRef: fileRef, popoverSource: nil)
        navigationController.pushViewController(databaseInfoVC, animated: true)
    }

    func showDatabaseUnlocker(database: URLReference, animated: Bool, completion: (()->Void)?) {
        let storedDatabaseKey: SecureByteArray?
        do {
            storedDatabaseKey = try Keychain.shared.getDatabaseKey(databaseRef: database)
                // throws KeychainError
        } catch {
            storedDatabaseKey = nil
            Diag.warning("Keychain error [message: \(error.localizedDescription)]")
            // just log, nothing else
        }
        
        let vc = DatabaseUnlockerVC.instantiateFromStoryboard()
        vc.delegate = self
        vc.coordinator = self
        vc.databaseRef = database
        vc.shouldAutofocus = (storedDatabaseKey == nil)
        navigationController.pushViewController(vc, animated: animated)
        completion?()
        if let storedDatabaseKey = storedDatabaseKey {
            tryToUnlockDatabase(database: database, compositeKey: storedDatabaseKey)
        }
    }
    
    func addKeyFile() {
        let picker = UIDocumentPickerViewController(documentTypes: FileType.keyFileUTIs, in: .open)
        picker.delegate = self
        navigationController.topViewController?.present(picker, animated: true, completion: nil)
        
        // remember the instance to recognize it in delegate method
        addKeyFilePicker = picker
    }
    
    func removeKeyFile(_ urlRef: URLReference) {
        //TODO: ask for confirmation
        FileKeeper.shared.removeExternalReference(urlRef, fileType: .keyFile)
        refreshFileList()
    }
    
    func selectKeyFile() {
        let vc = KeyFileChooserVC.instantiateFromStoryboard()
        vc.coordinator = self
        vc.delegate = self
        navigationController.pushViewController(vc, animated: true)
    }
    
    func showDiagnostics() {
        let vc = DiagnosticsViewerVC.instantiateFromStoryboard()
        vc.delegate = self
        navigationController.pushViewController(vc, animated: true)
    }
    
    func showDatabaseContent(database: Database, databaseRef: URLReference) {
        let fileName = databaseRef.info.fileName
        let databaseName = URL(string: fileName)?.deletingPathExtension().absoluteString ?? fileName
        
        let entriesVC = EntryFinderVC.instantiateFromStoryboard()
        entriesVC.coordinator = self
        entriesVC.delegate = self
        entriesVC.database = database
        entriesVC.databaseName = databaseName
        entriesVC.serviceIdentifiers = serviceIdentifiers

        var vcs = navigationController.viewControllers
        vcs[vcs.count - 1] = entriesVC
        navigationController.setViewControllers(vcs, animated: true)
    }
}

extension MainCoordinator: DatabaseChooserDelegate {
    func databaseChooserShouldCancel(_ sender: DatabaseChooserVC) {
        watchdog.restart()
        dismissAndQuit()
    }
    
    func databaseChooserShouldAddDatabase(_ sender: DatabaseChooserVC) {
        watchdog.restart()
        addDatabase()
    }
    
    func databaseChooser(_ sender: DatabaseChooserVC, didSelectDatabase urlRef: URLReference) {
        watchdog.restart()
        showDatabaseUnlocker(database: urlRef, animated: true, completion: nil)
    }
    
    func databaseChooser(_ sender: DatabaseChooserVC, shouldRemoveDatabase urlRef: URLReference) {
        watchdog.restart()
        removeDatabase(urlRef)
    }
    
    func databaseChooser(_ sender: DatabaseChooserVC, shouldShowInfoForDatabase urlRef: URLReference) {
        watchdog.restart()
        showDatabaseFileInfo(fileRef: urlRef)
    }
}

extension MainCoordinator: DatabaseUnlockerDelegate {
    func databaseUnlockerShouldUnlock(
        _ sender: DatabaseUnlockerVC,
        database: URLReference,
        password: String,
        keyFile: URLReference?)
    {
        watchdog.restart()
        tryToUnlockDatabase(database: database, password: password, keyFile: keyFile)
    }
}

extension MainCoordinator: KeyFileChooserDelegate {
    
    func keyFileChooser(_ sender: KeyFileChooserVC, didSelectFile urlRef: URLReference?) {
        watchdog.restart()
        navigationController.popViewController(animated: true) // bye-bye, key file chooser
        if let databaseUnlockerVC = navigationController.topViewController as? DatabaseUnlockerVC {
            databaseUnlockerVC.setKeyFile(urlRef: urlRef)
        } else {
            assertionFailure()
        }
    }
}

extension MainCoordinator: DatabaseManagerObserver {
    
    func databaseManager(willLoadDatabase urlRef: URLReference) {
        guard let databaseUnlockerVC = navigationController.topViewController
            as? DatabaseUnlockerVC else { return }
        databaseUnlockerVC.showProgressOverlay(animated: !isLoadingUsingStoredDatabaseKey)
    }

    func databaseManager(progressDidChange progress: ProgressEx) {
        guard let databaseUnlockerVC = navigationController.topViewController
            as? DatabaseUnlockerVC else { return }
        databaseUnlockerVC.updateProgress(with: progress)
    }
    
    func databaseManager(database urlRef: URLReference, isCancelled: Bool) {
        guard let databaseUnlockerVC = navigationController.topViewController
            as? DatabaseUnlockerVC else { return }
        databaseUnlockerVC.hideProgressOverlay()
    }
    
    func databaseManager(database urlRef: URLReference, invalidMasterKey message: String) {
        guard let databaseUnlockerVC = navigationController.topViewController
            as? DatabaseUnlockerVC else { return }
        databaseUnlockerVC.hideProgressOverlay()
        databaseUnlockerVC.showMasterKeyInvalid(message: message)
    }
    
    func databaseManager(database urlRef: URLReference, loadingError message: String, reason: String?) {
        guard let databaseUnlockerVC = navigationController.topViewController
            as? DatabaseUnlockerVC else { return }
        databaseUnlockerVC.hideProgressOverlay()

        let errorText = (reason != nil) ? (message + "\n" + reason!) : message
        databaseUnlockerVC.showErrorMessage(text: errorText)
    }
    
    func databaseManager(didLoadDatabase urlRef: URLReference) {
        // not hiding progress overlay, for nicer transition
        
        if Settings.current.isRememberDatabaseKey {
            do {
                try DatabaseManager.shared.rememberDatabaseKey() // throws KeychainError
            } catch {
                Diag.warning("Failed to remember database key [message: \(error.localizedDescription)]")
                // only log, nothing else
            }
        }

        guard let database = DatabaseManager.shared.database else { fatalError() }
        showDatabaseContent(database: database, databaseRef: urlRef)
    }
}

extension MainCoordinator: UIDocumentPickerDelegate {
    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        watchdog.restart()
    }
    
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        watchdog.restart()
        guard let url = urls.first else { return }
        if controller === addDatabasePicker {
            addDatabaseURL(url)
        } else if controller === addKeyFilePicker {
            addKeyFileURL(url)
        }
    }
    
    private func addDatabaseURL(_ url: URL) {
        guard FileType.isDatabaseFile(url: url) else {
            let fileName = url.lastPathComponent
            let errorAlert = UIAlertController.make(
                title: LString.titleWarning,
                message: NSLocalizedString(
                    "Selected file \"\(fileName)\" does not look like a database.",
                    comment: "Warning when trying to add a file"),
                cancelButtonTitle: LString.actionOK)
            navigationController.present(errorAlert, animated: true, completion: nil)
            return
        }
        
        FileKeeper.shared.prepareToAddFile(url: url, mode: .openInPlace)
        FileKeeper.shared.processPendingOperations(
            success: { (urlRef) in
                self.navigationController.popToRootViewController(animated: true)
                self.refreshFileList()
            },
            error: { (error) in
                let alert = UIAlertController.make(
                    title: LString.titleError,
                    message: error.localizedDescription)
                self.navigationController.present(alert, animated: true, completion: nil)
            }
        )
    }

    private func addKeyFileURL(_ url: URL) {
        if FileType.isDatabaseFile(url: url) {
            let errorAlert = UIAlertController.make(
                title: LString.titleWarning,
                message: LString.dontUseDatabaseAsKeyFile,
                cancelButtonTitle: LString.actionOK)
            navigationController.present(errorAlert, animated: true, completion: nil)
            return
        }

        FileKeeper.shared.prepareToAddFile(url: url, mode: .openInPlace)
        FileKeeper.shared.processPendingOperations(
            success: { [weak self] (urlRef) in
                self?.refreshFileList()
            },
            error: { [weak self] (error) in
                let alert = UIAlertController.make(
                    title: LString.titleError,
                    message: error.localizedDescription)
                self?.navigationController.present(alert, animated: true, completion: nil)
            }
        )
    }
}

extension MainCoordinator: UINavigationControllerDelegate {
    func navigationController(
        _ navigationController: UINavigationController,
        willShow viewController: UIViewController,
        animated: Bool)
    {
        // make sure the VC is popping
        guard let fromVC = navigationController.transitionCoordinator?.viewController(forKey: .from),
            !navigationController.viewControllers.contains(fromVC) else { return }
        
        if fromVC is EntryFinderVC {
            DatabaseManager.shared.closeDatabase(clearStoredKey: false)
//            navigationController.popToRootViewController(animated: true)
        }
    }
}

extension MainCoordinator: EntryFinderDelegate {
    func entryFinder(_ sender: EntryFinderVC, didSelectEntry entry: Entry) {
        returnCredentials(entry: entry)
    }
    
    func entryFinderShouldLockDatabase(_ sender: EntryFinderVC) {
        DatabaseManager.shared.closeDatabase(clearStoredKey: true)
        navigationController.popToRootViewController(animated: true)
    }
}

extension MainCoordinator: DiagnosticsViewerDelegate {
    func diagnosticsViewer(_ sender: DiagnosticsViewerVC, didCopyContents text: String) {
        let infoAlert = UIAlertController.make(
            title: nil,
            message: NSLocalizedString(
                "Diagnostic log has been copied to clipboard.",
                comment: "[Diagnostics] notification/confirmation message"),
            cancelButtonTitle: LString.actionOK)
        navigationController.present(infoAlert, animated: true, completion: nil)
    }
}

extension MainCoordinator: WatchdogDelegate {
    var isAppLockVisible: Bool {
        return isBiometricAuthShown || isPasscodeInputShown
    }
    
    func showAppLock(_ sender: Watchdog) {
        guard !isAppLockVisible else { return }
        let shouldUseBiometrics = isBiometricAuthAvailable()
        passcodeInputController = PasscodeInputVC.instantiateFromStoryboard()
        passcodeInputController!.delegate = self
        passcodeInputController!.mode = .verification
        passcodeInputController!.isCancelAllowed = true
        passcodeInputController!.isBiometricsAllowed = shouldUseBiometrics
        // Auto-appearing keyboard messes up the biometrics UI,
        // so don't show the keyboard if there will be biometrics.
        passcodeInputController!.shouldActivateKeyboard = !shouldUseBiometrics
        
        if rootController.presentedViewController != nil {
            // we are already showing navigationController, replace it
            rootController.dismiss(animated: false) {
                [weak self] in
                guard let _self = self else { return }
                _self.rootController.present(_self.passcodeInputController!, animated: false) {
                    [weak self] in
                    self?.showBiometricAuth()
                }
                _self.isPasscodeInputShown = true
            }
        } else {
            // the rootController is empty, so we can present directly
            rootController.present(passcodeInputController!, animated: false, completion: {
                [weak self] in
                self?.showBiometricAuth()
            })
            isPasscodeInputShown = true
        }
        
    }
    
    func hideAppLock(_ sender: Watchdog) {
        dismissPasscodeAndContinue()
    }
    
    func watchdogDidCloseDatabase(_ sender: Watchdog) {
        navigationController.popToRootViewController(animated: true)
    }
    
    private func dismissPasscodeAndContinue() {
        guard rootController.presentedViewController === passcodeInputController else { return }
        rootController.dismiss(animated: true) {
            [weak self] in
            guard let _self = self else { return }
            _self.passcodeInputController = nil
            _self.rootController.present(_self.navigationController, animated: false, completion: nil)
        }
        isPasscodeInputShown = false
        watchdog.restart()
    }
    
    private func isBiometricAuthAvailable() -> Bool {
        guard Settings.current.isBiometricAppLockEnabled else { return false }
        let context = LAContext()
        let policy = LAPolicy.deviceOwnerAuthenticationWithBiometrics
        return context.canEvaluatePolicy(policy, error: nil)
    }
    
    /// Shows biometric authentication UI, if supported and enabled.
    private func showBiometricAuth() {
        guard isBiometricAuthAvailable() else {
            isBiometricAuthShown = false
            return
        }

        let context = LAContext()
        let policy = LAPolicy.deviceOwnerAuthenticationWithBiometrics
        context.localizedFallbackTitle = "" // hide "Enter Password" fallback; nil won't work
        
        Diag.debug("Biometric auth: showing request")
        context.evaluatePolicy(policy, localizedReason: LString.titleTouchID) {
            [weak self](authSuccessful, authError) in
            self?.isBiometricAuthShown = false
            if authSuccessful {
                Diag.info("Biometric auth successful")
                DispatchQueue.main.async {
                    [weak self] in
                    self?.dismissPasscodeAndContinue()
                }
            } else {
                Diag.warning("Biometric auth failed [message: \(authError?.localizedDescription ?? "nil")]")
                DispatchQueue.main.async {
                    [weak self] in
                    self?.passcodeInputController?.becomeFirstResponder()
                }
            }
        }
        isBiometricAuthShown = true
    }
}

extension MainCoordinator: PasscodeInputDelegate {
    func passcodeInputDidCancel(_ sender: PasscodeInputVC) {
        dismissAndQuit()
    }
    
    func passcodeInput(_ sender: PasscodeInputVC, didEnterPasscode passcode: String) {
        do {
            if try Keychain.shared.isAppPasscodeMatch(passcode) { // throws KeychainError
                dismissPasscodeAndContinue()
            } else {
                sender.animateWrongPassccode()
            }
        } catch {
            Diag.error(error.localizedDescription)
            let alert = UIAlertController.make(
                title: LString.titleKeychainError,
                message: error.localizedDescription)
            sender.present(alert, animated: true, completion: nil)
        }
    }
    
    func passcodeInputDidRequestBiometrics(_ sender: PasscodeInputVC) {
        showBiometricAuth()
    }
}
