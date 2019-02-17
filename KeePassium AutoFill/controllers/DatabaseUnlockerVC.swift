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

import KeePassiumLib

protocol DatabaseUnlockerDelegate: class {
    /// Called when the user presses "Unlock"
    func databaseUnlockerShouldUnlock(
        _ sender: DatabaseUnlockerVC,
        database: URLReference,
        password: String,
        keyFile: URLReference?)
}

class DatabaseUnlockerVC: UIViewController, Refreshable {

    @IBOutlet weak var errorMessagePanel: UIView!
    @IBOutlet weak var errorMessageLabel: UILabel!
    @IBOutlet weak var errorDetailsButton: UIButton!
    @IBOutlet weak var databaseLocationIconImage: UIImageView!
    @IBOutlet weak var databaseFileNameLabel: UILabel!
    @IBOutlet weak var inputPanel: UIView!
    @IBOutlet weak var passwordField: ProtectedTextField!
    @IBOutlet weak var keyFileField: UITextField!
    @IBOutlet weak var rememberMasterKeySwitch: UISwitch!
    
    weak var coordinator: MainCoordinator?
    weak var delegate: DatabaseUnlockerDelegate?
    var shouldAutofocus = false
    var databaseRef: URLReference? {
        didSet { refresh() }
    }
    private(set) var keyFileRef: URLReference?
    
    override func viewDidLoad() {
        super.viewDidLoad()
        rememberMasterKeySwitch.isOn = Settings.current.isRememberDatabaseKey
        
        // make background image
        view.backgroundColor = UIColor(patternImage: UIImage(asset: .backgroundPattern))
        view.layer.isOpaque = false
        
        errorMessagePanel.alpha = 0.0
        
        refresh()
        
        keyFileField.delegate = self
        passwordField.delegate = self
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        navigationController?.setToolbarHidden(true, animated: true)
        if shouldAutofocus {
            DispatchQueue.main.async { [weak self] in
                self?.passwordField?.becomeFirstResponder()
            }
        }
    }
    
    func showErrorMessage(text: String) {
        errorMessageLabel.text = " " + text + " "
        UIView.animate(
            withDuration: 0.3,
            delay: 0.0,
            options: .curveEaseIn,
            animations: {
                [weak self] in
                self?.errorMessagePanel.alpha = 1.0
            },
            completion: {
                [weak self] (finished) in
                self?.errorMessagePanel.shake()
            }
        )
    }
    
    func hideErrorMessage(animated: Bool) {
        if animated {
            UIView.animate(
                withDuration: 0.3,
                delay: 0.0,
                options: .curveEaseOut,
                animations: {
                    [weak self] in
                    self?.errorMessagePanel.alpha = 0.0
                },
                completion: {
                    [weak self] (finished) in
                    self?.errorMessageLabel.text = " "
                }
            )
        } else {
            errorMessagePanel.alpha = 0.0
            errorMessageLabel.text = " "
        }
    }

    func showMasterKeyInvalid(message: String) {
        showErrorMessage(text: message)
    }
    
    func refresh() {
        guard isViewLoaded else { return }
        guard let dbRef = databaseRef else {
            databaseLocationIconImage.image = nil
            databaseFileNameLabel.text = ""
            return
        }
        let fileInfo = dbRef.info
        if let errorMessage = fileInfo.errorMessage {
            databaseFileNameLabel.text = errorMessage
            databaseFileNameLabel.textColor = UIColor.errorMessage
            databaseLocationIconImage.image = nil
        } else {
            databaseFileNameLabel.text = fileInfo.fileName
            databaseFileNameLabel.textColor = UIColor.primaryText
            databaseLocationIconImage.image = UIImage.databaseIcon(for: dbRef)
        }
        
        let settings = Settings.current
        if let associatedKeyFileRef = settings.getKeyFileForDatabase(databaseRef: dbRef) {
            setKeyFile(urlRef: associatedKeyFileRef)
        }
    }
    
    func setKeyFile(urlRef: URLReference?) {
        // can be nil, can have error, can be ok
        keyFileRef = urlRef
        
        hideErrorMessage(animated: false)

        guard let databaseRef = databaseRef else { return }
        Settings.current.setKeyFileForDatabase(databaseRef: databaseRef, keyFileRef: keyFileRef)
        
        guard let fileInfo = urlRef?.info else {
            Diag.debug("No key file selected")
            keyFileField.text = ""
            return
        }
        if let errorDetails = fileInfo.errorMessage {
            let errorMessage = NSLocalizedString("Key file error: \(errorDetails)", comment: "Error message related to key file")
            Diag.warning(errorMessage)
            showErrorMessage(text: errorMessage)
            keyFileField.text = ""
        } else {
            Diag.info("Key file set successfully")
            keyFileField.text = fileInfo.fileName
        }
    }
    
    // MARK: - Progress overlay
    private(set) var progressOverlay: ProgressOverlay?

    public func showProgressOverlay(animated: Bool) {
        navigationItem.hidesBackButton = true
        progressOverlay = ProgressOverlay.addTo(
            self.view,
            title: LString.databaseStatusLoading,
            animated: animated)
    }
    
    public func updateProgress(with progress: ProgressEx) {
        progressOverlay?.update(with: progress)
    }
    
    public func hideProgressOverlay() {
        navigationItem.hidesBackButton = false
        progressOverlay?.dismiss(animated: true) {
            [weak self] (finished) in
            guard finished, let _self = self else { return }
            _self.progressOverlay?.removeFromSuperview()
            _self.progressOverlay = nil
        }
    }

    
    // MARK: - Actions
    
    @IBAction func didPressErrorDetailsButton(_ sender: Any) {
        Watchdog.shared.restart()
        coordinator?.showDiagnostics()
    }
    
    @IBAction func didToggleRememberSwitch(_ sender: Any) {
        Watchdog.shared.restart()
        Settings.current.isRememberDatabaseKey = rememberMasterKeySwitch.isOn
    }
    
    @IBAction func didPressUnlock(_ sender: Any) {
        Watchdog.shared.restart()
        guard let databaseRef = databaseRef else { return }
        delegate?.databaseUnlockerShouldUnlock(
            self,
            database: databaseRef,
            password: passwordField.text ?? "",
            keyFile: keyFileRef)
        passwordField.text = "" 
    }
}

extension DatabaseUnlockerVC: UITextFieldDelegate {
    func textFieldDidBeginEditing(_ textField: UITextField) {
        Watchdog.shared.restart()
        if textField === keyFileField {
            coordinator?.selectKeyFile()
            passwordField.becomeFirstResponder()
        }
    }
    
    func textField(
        _ textField: UITextField,
        shouldChangeCharactersIn range: NSRange,
        replacementString string: String) -> Bool
    {
        hideErrorMessage(animated: true)
        return true
    }
    
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if textField === passwordField {
            didPressUnlock(textField)
            return false
        }
        return true // use default behavior
    }
}
