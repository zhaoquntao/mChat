//
//  ChatVC.swift
//  mChat
//
//  Created by Vitaliy Paliy on 11/21/19.
//  Copyright © 2019 PALIY. All rights reserved.
//

import UIKit
import Firebase
import AVFoundation

class ChatVC: UIViewController,UIImagePickerControllerDelegate, UINavigationControllerDelegate, AVAudioRecorderDelegate {
    
    var friend: FriendInfo!
    var messages = [Messages]()
    let chatNetworking = ChatNetworking()
    let chatAudio = ChatAudio()
    var userResponse = UserResponse()
    
    var containerHeight: CGFloat!
    var collectionView: MessageCollectionView!
    var messageContainer: MessageContainer!
    var refreshIndicator: MessageLoadingIndicator!
    
    let calendar = Calendar(identifier: .gregorian)
    
    override func viewDidLoad() {
        super.viewDidLoad()
        setupChat()
        view.backgroundColor = UIColor(white: 0.95, alpha: 1)
        notificationCenterHandler()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        tabBarController?.tabBar.isHidden = true
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        chatNetworking.removeObserves()
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        var topConst: CGFloat!
        if view.safeAreaInsets.bottom > 0 {
            containerHeight = 70
            topConst = 28
        }else{
            containerHeight = 45
            topConst = 8
        }
        messageContainer = MessageContainer(height: containerHeight, const: topConst, chatVC: self)
        collectionView = MessageCollectionView(collectionViewLayout: UICollectionViewFlowLayout.init(), chatVC: self)
        refreshIndicator = MessageLoadingIndicator(frame: view.frame, const: topConst, chatVC: self)
        hideKeyboardOnTap()
    }
    
    func setupChat(){
        chatNetworking.friend = friend
        setupChatNavBar()
        fetchMessages()
        navigationItem.rightBarButtonItem = UIBarButtonItem(customView: ProfileImageButton(chatVC: self, url: friend.profileImage))
        observeFriendTyping()
    }
    
    func setupChatNavBar(){
        let loginDate = NSDate(timeIntervalSince1970: friend.lastLogin.doubleValue)
        navigationController?.navigationBar.tintColor = .black
        if friend.isOnline {
            navigationItem.setNavTitles(navTitle: friend.name, navSubtitle: "Online")
        }else{
            navigationItem.setNavTitles(navTitle: friend.name, navSubtitle: calendar.calculateLastLogin(loginDate))
        }
    }

    @objc func clipImageButtonPressed() {
        openImagePicker(type: .photoLibrary)
    }
    
    func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
        if let originalImage = info[UIImagePickerController.InfoKey.originalImage] as? UIImage {
            chatNetworking.uploadImage(image: originalImage)
            dismiss(animated: true, completion: nil)
        }
    }
    
    func openImagePicker(type: UIImagePickerController.SourceType){
        let picker = UIImagePickerController()
        picker.delegate = self
        picker.sourceType = type
        present(picker, animated: true, completion: nil)
    }
    
    @objc func sendButtonPressed(){
        setupTextMessage()
    }
    
    func hideKeyboardOnTap(){
        let tap: UITapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(hideKeyboard))
        tap.cancelsTouchesInView = false
        collectionView.addGestureRecognizer(tap)
        navigationController?.navigationBar.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(hideKeyboard)))
    }
    
    @objc func hideKeyboard(){
        view.endEditing(true)
    }
    
    func setupTextMessage(){
        let trimmedMessage = messageContainer.messageTV.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedMessage.count > 0 else { return }
        let senderRef = Constants.db.reference().child("messages").child(CurrentUser.uid).child(friend.id).childByAutoId()
        let friendRef = Constants.db.reference().child("messages").child(friend.id).child(CurrentUser.uid).child(senderRef.key!)
        guard let messageId = senderRef.key else { return }
        var values = ["message": trimmedMessage, "sender": CurrentUser.uid!, "recipient": friend.id!, "time": Date().timeIntervalSince1970, "messageId": messageId] as [String : Any]
        if userResponse.repliedMessage != nil || userResponse.messageToForward != nil{
            let repValues = userResponse.messageToForward != nil ? userResponse.messageToForward : userResponse.repliedMessage
            if repValues?.message != nil {
                values["repMessage"] = repValues?.message
            }else if repValues?.mediaUrl != nil{
                values["repMediaMessage"] = repValues?.mediaUrl
            }
            values["repMID"] = repValues?.id
            values["repSender"] = userResponse.messageSender
            exitResponseButtonPressed()
        }
        chatNetworking.sendMessageHandler(senderRef: senderRef, friendRef: friendRef, values: values) { (error) in
            self.handleMessageTextSent(error)
        }
    }
    
    func handleMessageTextSent(_ error: Error?){
        guard error == nil else {
            showAlert(title: "Error", message: error?.localizedDescription)
            return
        }
        messageContainer.messageTV.text = ""
        messageContainer.messageTV.subviews[2].isHidden = false
        self.scrollToTheBottom(animated: false)
        hideKeyboard()
        chatNetworking.disableIsTyping()
        messageContainer.messageTV.constraints.forEach { (constraint) in
            if constraint.firstAttribute == .height {
                constraint.constant = 32
                if sendingIsFinished(const: messageContainer.heightAnchr){ return }
            }
            view.layoutIfNeeded()
        }
    }
    
    func fetchMessages(){
        chatNetworking.loadMore = true
        chatNetworking.scrollToIndex = []
        chatNetworking.getMessages(view, messages) { (newMessages, order) in
            self.chatNetworking.lastMessageReached = newMessages.count == 0
            if self.chatNetworking.lastMessageReached {
                print("message.count == 0")
                self.observeMessageActions()
                return
            }
            self.chatNetworking.scrollToIndex = newMessages
            self.chatNetworking.timer.invalidate()
            self.refreshIndicator.startAnimating()
            if order {
                self.refreshIndicator.order = order
                self.messages.append(contentsOf: newMessages)
            }else{
                self.refreshIndicator.order = order
                self.messages.insert(contentsOf: newMessages, at: 0)
            }
            self.handleReload()
        }
    }
    
    func observeMessageActions(){
        let ref = Database.database().reference().child("messages").child(CurrentUser.uid).child(friend.id)
        ref.observe(.childRemoved) { (snap) in
            self.chatNetworking.deleteMessageHandler(self.messages, for: snap) { (index) in
                self.messages.remove(at: index)
                self.collectionView.deleteItems(at: [IndexPath(item: index, section: 0)])
            }
        }
        ref.queryLimited(toLast: 1).observe(.childAdded) { (snap) in
            self.chatNetworking.newMessageRecievedHandler(self.messages, for: snap) { (newMessage) in
                self.messages.append(newMessage)
                self.collectionView.reloadData()
                if newMessage.determineUser() != CurrentUser.uid {
                    self.scrollToTheBottom(animated: true)
                }
            }
        }
    }
    
    func handleReload(){
        print("reloaded")
        DispatchQueue.main.async {
            self.collectionView.reloadData()
            if self.refreshIndicator.order{
                self.scrollToTheBottom(animated: false)
            }else{
                let index = self.chatNetworking.scrollToIndex.count - 1
                self.collectionView.scrollToItem(at: IndexPath(item: index, section: 0), at: .top, animated: false)
            }
            self.chatNetworking.loadMore = false
            self.refreshIndicator.stopAnimating()
        }
        observeMessageActions()
    }
    
    @objc func profileImageTapped(){
        let friendController = FriendInformationVC()
        friendController.friend = friend
        friendController.modalPresentationStyle = .fullScreen
        show(friendController, sender: self)
    }
    
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        sendButtonPressed()
        return true
    }
    
    func zoomImageHandler(image: UIImageView) {
        view.endEditing(true)
        let _ = SelectedImageView(image, self)
    }
    
    func messageContainerHeightHandler(_ const: NSLayoutConstraint, _ estSize: CGSize){
        if sendingIsFinished(const: const) { return }
        var height = estSize.height
        if userResponse.responseStatus { height = estSize.height + 50 }
        if height > 150 { return }
        if messageContainer.messageTV.calculateLines() >= 2 {
            if containerHeight > 45 {
                const.constant = height + 35
            }else{ const.constant = height + 15 }
        }
    }
    
    func messageHeightHandler(_ constraint: NSLayoutConstraint, _ estSize: CGSize){
        let height: CGFloat = userResponse.responseStatus == true ? 100 : 150
        if estSize.height > height{
            messageContainer.messageTV.isScrollEnabled = true
            return
        }else if messageContainer.messageTV.calculateLines() < 2 {
            constraint.constant = 32
            self.view.layoutIfNeeded()
            return
        }
        constraint.constant = estSize.height
        self.view.layoutIfNeeded()
    }
    
    func sendingIsFinished(const: NSLayoutConstraint) -> Bool{
        let height: CGFloat = userResponse.responseStatus == true ? containerHeight + 50 : containerHeight
        if messageContainer.messageTV.text.count == 0 {
            messageContainer.messageTV.isScrollEnabled = false
            const.constant = height
            return true
        }else{
            return false
        }
    }
    
    func notificationCenterHandler() {
        NotificationCenter.default.addObserver(self, selector: #selector(handleKeyboardWillShow(notification:)), name: UIResponder.keyboardWillShowNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(handleKeyboardWillHide(notification:)), name: UIResponder.keyboardWillHideNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(willResignActive), name: UIApplication.willResignActiveNotification, object: nil)
    }
    
    @objc func willResignActive(_ notification: Notification) {
        chatNetworking.disableIsTyping()
    }
    
    @objc func handleKeyboardWillShow(notification: NSNotification){
        let kFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
        let kDuration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double
        guard let height = kFrame?.height, let duration = kDuration else { return }
        if containerHeight > 45 {
            messageContainer.bottomAnchr.constant = 13.2
            collectionView.contentOffset.y -= 13.2
        }
        messageContainer.bottomAnchr.constant -= height
        collectionView.contentOffset.y += height
        UIView.animate(withDuration: duration) {
            self.view.layoutIfNeeded()
        }
    }
    
    @objc func handleKeyboardWillHide(notification: NSNotification){
        let kFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
        let kDuration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double
        guard let height = kFrame?.height else { return }
        guard let duration = kDuration else { return }
        if containerHeight > 45 {
            collectionView.contentOffset.y += 13.2
        }
        collectionView.contentOffset.y -= height
        messageContainer.bottomAnchr.constant = 0
        UIView.animate(withDuration: duration) {
            self.view.layoutIfNeeded()
        }
    }
    
    func animateActionButton(){
        var buttonToAnimate = UIButton()
        if messageContainer.messageTV.text.count >= 1 {
            messageContainer.micButton.alpha = 0
            if messageContainer.sendButton.alpha == 1 { return }
            messageContainer.sendButton.alpha = 1
            buttonToAnimate = messageContainer.sendButton
        }else if messageContainer.messageTV.text.count == 0{
            messageContainer.micButton.alpha = 1
            messageContainer.sendButton.alpha = 0
            buttonToAnimate = messageContainer.micButton
        }
        buttonToAnimate.transform = CGAffineTransform(scaleX: 0.2, y: 0.2)
        UIView.animate(withDuration: 0.55, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 1, options: .curveEaseIn, animations: {
            buttonToAnimate.transform = .identity
        })
    }
    
    func observeFriendTyping(){
        chatNetworking.observeIsUserTyping() { (friendActivity) in
            if friendActivity.friendId == self.friend.id && friendActivity.isTyping {
                self.navigationItem.setupTypingNavTitle(navTitle: self.friend.name)
            }else{
                self.setupChatNavBar()
            }
        }
    }
    
    func scrollToTheBottom(animated: Bool){
        if messages.count > 0 {
            let indexPath = IndexPath(item: messages.count - 1, section: 0)
            collectionView.scrollToItem(at: indexPath, at: .bottom, animated: animated)
        }
    }
    
    @objc func handleLongPressGesture(longPress: UILongPressGestureRecognizer){
        if longPress.state != UIGestureRecognizer.State.began { return }
        let point = longPress.location(in: collectionView)
        guard let indexPath = collectionView.indexPathForItem(at: point) else { return }
        guard let cell = collectionView.cellForItem(at: indexPath) as? ChatCell else { return }
        let message = messages[indexPath.row]
        openToolsMenu(message, cell)
    }
    
    func openToolsMenu(_ message: Messages, _ selectedCell: ChatCell){
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        hideKeyboard()
        collectionView.isUserInteractionEnabled = false
        selectedCell.isHidden = true
        let _ = ToolsMenu(message, selectedCell, self)
    }
    
    func forwardButtonPressed(_ message: Messages) {
        chatNetworking.getMessageSender(message: message) { (name) in
            self.userResponse.messageToForward = message
            let convController = NewConversationVC()
            convController.forwardDelegate = self
            convController.forwardName = name
            let navController = UINavigationController(rootViewController: convController)
            self.present(navController, animated: true, completion: nil)
        }
    }
    
    func responseButtonPressed(_ message: Messages, forwardedName: String? = nil){
        responseViewChangeAlpha(a: 0)
        messageContainer.micButton.alpha = 0
        messageContainer.sendButton.alpha = 1
        messageContainer.messageTV.becomeFirstResponder()
        userResponse.responseStatus = true
        userResponse.repliedMessage = message
        messageContainer.heightAnchr.constant += 50
        UIView.animate(withDuration: 0.1, animations: {
            self.view.layoutIfNeeded()
            self.responseMessageLine(message, forwardedName)
        }) { (true) in
            self.responseViewChangeAlpha(a: 1)
        }
    }
    
    
    @objc func handleAudioRecording(){
        chatAudio.recordingSession = AVAudioSession.sharedInstance()
        if !chatAudio.requestPermisson() { return }
        if chatAudio.audioRecorder == nil {
            startAudioRecording()
        }else{
            stopAudioRecording()
        }
    }
    
    func startAudioRecording(){
        let fileName = chatAudio.getDirectory().appendingPathComponent("sentAudio.m4a")
        let settings = [AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: 12000, AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue]
        do{
            chatAudio.audioRecorder = try AVAudioRecorder(url: fileName, settings: settings)
            chatAudio.audioRecorder.delegate = self
            chatAudio.audioRecorder.record()
            prepareContainerForRecording()
        }catch{
            showAlert(title: "Error", message: error.localizedDescription)
        }
    }
    
    func prepareContainerForRecording(){
        chatAudio.timer = Timer(timeInterval: 1.0, target: self, selector: #selector(audioTimerHandler), userInfo: nil, repeats: true)
        RunLoop.current.add(chatAudio.timer, forMode: RunLoop.Mode.common)
        messageContainer.micButton.setImage(UIImage(systemName: "stop.circle"), for: .normal)
        messageContainer.recordingLabel.isHidden = false
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0, options: .curveEaseIn, animations: {
            self.messageContainer.recordingLabel.frame.origin.x += self.messageContainer.frame.width/6
            self.messageContainer.messageTV.frame.origin.y += self.containerHeight
            self.messageContainer.clipImageButton.frame.origin.y += self.containerHeight
            self.view.layoutIfNeeded()
            self.messageContainer.recordingAudioView.isHidden = false
        }) { (true) in
            self.messageContainer.actionCircle.isHidden = false
        }
    }
    
    @objc func audioTimerHandler(){
        chatAudio.timePassed += 1
        let (m,s) = chatAudio.timePassedFrom(seconds: chatAudio.timePassed)
        let minutes = m < 10 ? "0\(m)" : "\(m)"
        let seconds = s < 10 ? "0\(s)" : "\(s)"
        messageContainer.recordingLabel.text = "\(minutes):\(seconds)"
    }
    
    func stopAudioRecording() {
        chatAudio.audioRecorder.stop()
        chatAudio.audioRecorder = nil
        chatAudio.timePassed = 0
        do{
            let data = try Data(contentsOf: chatAudio.getDirectory().appendingPathComponent("sentAudio.m4a"))
            chatNetworking.uploadAudio(file: data)
            removeRecordingUI()
        }catch{
            print(error.localizedDescription)
        }
    }
    
    func removeRecordingUI(){
        messageContainer.recordingAudioView.isHidden = true
        if chatAudio.timer != nil { chatAudio.timer.invalidate() }
        messageContainer.micButton.setImage(UIImage(systemName: "mic"), for: .normal)
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 1, initialSpringVelocity: 0, options: .curveEaseOut, animations: {
            self.messageContainer.actionCircle.isHidden = true
            self.messageContainer.recordingLabel.frame.origin.x -= self.messageContainer.frame.width/6
            self.messageContainer.messageTV.frame.origin.y -= self.containerHeight
            self.messageContainer.clipImageButton.frame.origin.y -= self.containerHeight
            self.view.layoutIfNeeded()
        }) { (true) in
            self.messageContainer.recordingAudioView.isHidden = true
            self.messageContainer.recordingLabel.text = "00:00"
        }
    }
    
    func handleUserPressedAudioButton(for cell: ChatCell){
        if chatAudio.audioPlayer == nil {
            chatAudio.audioPlayer = cell.audioPlayer
            chatAudio.audioPlayer?.play()
            cell.audioPlayButton.setImage(UIImage(systemName: "pause.circle.fill"), for: .normal)
            cell.timer = Timer(timeInterval: 0.3, target: cell, selector: #selector(cell.timerHandler), userInfo: nil, repeats: true)
            RunLoop.current.add(cell.timer, forMode: RunLoop.Mode.common)
        }else{
            chatAudio.audioPlayer?.pause()
        }
    }
    
}
