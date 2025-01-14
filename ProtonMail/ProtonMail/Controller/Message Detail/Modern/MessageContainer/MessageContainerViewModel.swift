//
//  MessageViewModel.swift
//  ProtonMail - Created on 07/03/2019.
//
//
//  Copyright (c) 2019 Proton Technologies AG
//
//  This file is part of ProtonMail.
//
//  ProtonMail is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  ProtonMail is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with ProtonMail.  If not, see <https://www.gnu.org/licenses/>.
    

import Foundation
import CoreData

/// ViewModel object of big MessaveViewController screen with a whole thread of messages inside. ViewModel objects of singular messages are nested in `thread` array.
class MessageContainerViewModel: TableContainerViewModel {
    internal lazy var userActivity: NSUserActivity = {
        let activity = NSUserActivity(activityType: "Handoff.Message")
        activity.isEligibleForHandoff = true
        activity.isEligibleForSearch = false
        activity.isEligibleForPublicIndexing = false
        if #available(iOS 12.0, *) {
            activity.isEligibleForPrediction = false
        }
        
        let deeplink = DeepLink(String(describing: MenuViewController.self))
        deeplink.append(.init(name: String(describing: MailboxViewController.self), value: Message.Location.inbox))
        deeplink.append(.init(name: String(describing: MessageContainerViewController.self), value: self.messages.first?.messageID))
        if let deeplinkData = try? JSONEncoder().encode(deeplink) {
            activity.addUserInfoEntries(from: ["deeplink": deeplinkData])
        }
        return activity
    }()
    
    private(set) var messages: [Message] {
        didSet {
            self.thread = messages.map(MessageViewModel.init)
        }
    }
    private var observationsHeader: [NSKeyValueObservation] = []
    private var observationsBody: [NSKeyValueObservation] = []
    private var attachmentsObservation: [NSKeyValueObservation] = []
    
    // model - viewModel connections
    @objc private(set) dynamic var thread: [MessageViewModel]
    internal func message(for standalone: MessageViewModel) -> Message? {
        return self.messages.first { $0.messageID == standalone.messageID }
    }
    
    override var numberOfSections: Int {
        return self.thread.count
    }
    
    override func numberOfRows(in section: Int) -> Int {
        return self.thread[section].divisionsCount
    }
    
    init(conversation messages: [Message]) {
        self.messages = messages
        self.thread = messages.map(MessageViewModel.init)
        
        super.init()
        
        NotificationCenter.default.addObserver(forName: .NSManagedObjectContextObjectsDidChange, object: nil, queue: nil) { [weak self] notification in
            guard let deletedObjects = notification.userInfo?[NSDeletedObjectsKey] as? NSSet,
                case let deleted = deletedObjects.compactMap({ $0 as? Message }) else
            {
                return
            }
            self?.messages.removeAll(where: deleted.contains)
        }
        
        NotificationCenter.default.addObserver(forName: NSNotification.Name.reachabilityChanged, object: nil, queue: nil) { [weak self] notification in
            guard let manager = notification.object as? Reachability,
                manager.currentReachabilityStatus() != .NotReachable else
            {
                return
            }
            
            if let _ = self?.messages.first(where: { !$0.isDetailDownloaded }) {
                self?.downloadThreadDetails()
            }
        }
    }
    
    convenience init(message: Message) {
        self.init(conversation: [message])
    }
    
    required convenience init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let messageIDs = try container.decode(Array<String>.self, forKey: .messageIDs)
        
        let messages = sharedMessageDataService.fetchMessages(withIDs: NSMutableSet(array: messageIDs))
        
        self.init(conversation: messages)
    }
    
    deinit {
        self.unsubscribeFromUpdatesOfChildren()
        NotificationCenter.default.removeObserver(self)
    }
    
    internal func locationsForMoreButton() -> [Message.Location] {
        let locations: Array<Message.Location> = [.inbox, .spam, .archive]
        let message = self.messages.first!
        let suitableLocations = locations.filter {
            !message.contains(label: $0) && !(message.contains(label: .sent) && $0 == .inbox)
        }
        return suitableLocations
    }
    
    internal func moveThread(to location: Message.Location) {
        messages.forEach { message in
            guard let label = message.firstValidFolder() else { return }
            sharedMessageDataService.move(message: message, from: label, to: location.rawValue)
        }
    }
    
    internal func reload(message: Message) {
        let standalone = self.thread.first { $0.messageID == message.messageID }
        standalone?.reload(from: message)
    }
    
    internal func reload(message: Message, with bodyPlaceholder: String) {
        let standalone = self.thread.first { $0.messageID == message.messageID }
        standalone?.body = bodyPlaceholder
    }
    
    internal func markThread(read: Bool) {
        self.messages.forEach {
            sharedMessageDataService.mark(message: $0, unRead: !read)
        }
    }
    
    internal func isRemoveIrreversible() -> Bool { // TODO: validation logic should be different for threads
        return self.messages.first(where: { $0.contains(label: .trash) || $0.contains(label: .spam) }) != nil
    }
    
    internal func removeThread() { // TODO: remove logic should be different for threads
        self.unsubscribeFromUpdatesOfChildren()
        self.messages.forEach { message in
            if message.contains(label: .trash) || message.contains(label: .spam) {
                sharedMessageDataService.delete(message: message, label: Message.Location.trash.rawValue)
            } else {
                if let label = message.firstValidFolder() {
                    sharedMessageDataService.move(message: message, from: label, to: Message.Location.trash.rawValue)
                }
            }
        }
    }
    
    internal func headersTemporaryUrl() -> URL? { // TODO: this one will not work for threads
        guard let message = self.messages.first else {
            assert(false, "No messages in thread")
            return URL(fileURLWithPath: "")
        }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let filename = "headers-" + formatter.string(from: message.time!) + "-" + message.title.components(separatedBy: CharacterSet.alphanumerics.inverted).joined(separator: "-")
        guard let header = message.header else {
            assert(false, "No header in message")
            return nil
        }
        return try? self.writeToTemporaryUrl(header, filename: filename)
    }
    
    internal func bodyTemporaryUrl() -> URL? { // TODO: this one will not work for threads
        guard let message = self.messages.first else {
            assert(false, "No messages in thread")
            return nil
        }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let filename = "body-" + formatter.string(from: message.time!) + "-" + message.title.components(separatedBy: CharacterSet.alphanumerics.inverted).joined(separator: "-")
        guard let body = try? message.decryptBodyIfNeeded() else {
            return nil
        }
        return try? self.writeToTemporaryUrl(body, filename: filename)
    }
    
    private func writeToTemporaryUrl(_ content: String, filename: String) throws -> URL {
        let tempFileUri = FileManager.default.temporaryDirectoryUrl.appendingPathComponent(filename, isDirectory: false).appendingPathExtension("txt")
        try? FileManager.default.removeItem(at: tempFileUri)
        try content.write(to: tempFileUri, atomically: true, encoding: .utf8)
        return tempFileUri
    }
    
    internal func reportPhishing(completion: @escaping (NSError?)->Void) { // TODO: this one will not work for threads
        guard let standalone = self.thread.first else {
            completion(NSError())
            assert(false, "No standalones in thread")
            return
        }

        BugDataService().reportPhishing(messageID: standalone.messageID, messageBody: standalone.body ?? LocalString._error_no_object) { error in
            completion(error)
        }
    }
    
    private func showErrorBanner(_ title: String) {
        self.showErrorBanner(title, action: self.downloadThreadDetails)
    }
    
    private func errorWhileReloading(message: Message, error: NSError) {
        switch error.code {
        case NSURLErrorTimedOut:
            self.showErrorBanner(LocalString._general_request_timed_out)
            self.reload(message: message, with: LocalString._general_request_timed_out)

        case NSURLErrorNotConnectedToInternet, NSURLErrorCannotConnectToHost:
            self.showErrorBanner(LocalString._general_no_connectivity_detected)
            self.reload(message: message, with: LocalString._general_no_connectivity_detected)

        case APIErrorCode.API_offline:
            self.showErrorBanner(error.localizedDescription)
            self.reload(message: message, with: error.localizedDescription)

        case APIErrorCode.HTTP503, NSURLErrorBadServerResponse:
            self.showErrorBanner(LocalString._general_api_server_not_reachable)
            self.reload(message: message, with: LocalString._general_api_server_not_reachable)

        default:
            self.showErrorBanner(LocalString._cant_download_message_body_please_try_again)
            self.reload(message: message, with: LocalString._cant_download_message_body_please_try_again)
        }
        PMLog.D("error: \(error)")
    }
    
    typealias ChildViewModelPack = (head: MessageHeaderViewModel, body: MessageBodyViewModel, attachments: MessageAttachmentsViewModel)
    internal func children() -> [ChildViewModelPack] {
        let children = self.thread.compactMap { standalone -> ChildViewModelPack? in
            guard let message = self.message(for: standalone) else { return nil }
            let head = MessageHeaderViewModel(parentViewModel: standalone, message: message)
            let attachments = MessageAttachmentsViewModel(parentViewModel: standalone)
            let body = MessageBodyViewModel(parentViewModel: standalone)
            return (head, body, attachments)
        }
        self.subscribe(toUpdatesOf: children)
        return children
    }
    
    private func subscribe(toUpdatesOf children: [ChildViewModelPack]) {
        self.unsubscribeFromUpdatesOfChildren()
        
        children.enumerated().forEach { index, child in
            let headObservation = child.head.observe(\.contentsHeight) { [weak self] head, _ in
                if let singleton = self?.thread.first(where: { $0.messageID == head.parentViewModel.messageID }) {
                    singleton.heightOfHeader = head.contentsHeight
                }
            }
            self.observationsHeader.append(headObservation)
            
            let attachmentsObservation = child.attachments.observe(\.contentsHeight) { [weak self] attachments, _ in
                if let singleton = self?.thread.first(where: { $0.messageID == attachments.parentViewModel.messageID }) {
                    singleton.heightOfAttachments = attachments.contentsHeight
                }
            }
            self.attachmentsObservation.append(attachmentsObservation)
            
            let bodyObservation = child.body.observe(\.contentHeight) { [weak self] body, _ in
                if let singleton = self?.thread.first(where: { $0.messageID == body.parentViewModel.messageID }) {
                    singleton.heightOfBody = body.contentHeight
                }
            }
            self.observationsBody.append(bodyObservation)
        }
    }
    
    private func unsubscribeFromUpdatesOfChildren() {
        self.observationsHeader = []
        self.observationsBody = []
        self.attachmentsObservation = []
    }
    
    internal func downloadThreadDetails() {
        self.messages.forEach { [weak self] message in
            message.fetchDetailIfNeeded() { _, _, _, error in
                guard error == nil else {
                    self?.errorWhileReloading(message: message, error: error!)
                    return
                }
                self?.reload(message: message)
            }
        }
    }
}

extension MessageContainerViewModel: Codable {
    enum CodingKeys: CodingKey {
        case messageIDs
    }
    
    enum Errors: Error {
        case decoding
    }
    
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        let messageIDs = self.thread.map { $0.messageID }
        try container.encode(messageIDs, forKey: .messageIDs)
    }
}
