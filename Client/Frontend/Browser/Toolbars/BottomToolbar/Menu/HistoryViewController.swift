/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import Shared
import BraveShared
import Storage
import Data
import CoreData

// MARK: - HistoryViewController

class HistoryViewController: SiteTableViewController, ToolbarUrlActionsProtocol {
    
    weak var toolbarUrlActionsDelegate: ToolbarUrlActionsDelegate?
    
    fileprivate lazy var emptyStateOverlayView = UIView().then {
        $0.backgroundColor = UIColor.white
    }
    
    var historyFRC: HistoryV2FetchResultsController?
    
    /// Certain bookmark actions are different in private browsing mode.
    let isPrivateBrowsing: Bool
    
    init(isPrivateBrowsing: Bool) {
        self.isPrivateBrowsing = isPrivateBrowsing
        super.init(nibName: nil, bundle: nil)
        
        historyFRC = Historyv2.frc()
        historyFRC?.delegate = self
    }
    
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        tableView.accessibilityIdentifier = "History List"
        title = Strings.historyScreenTitle
        
        reloadData()
    }
    
    override func reloadData() {
        // Recreate the frc if it was previously removed
        if historyFRC == nil {
            historyFRC = Historyv2.frc()
            historyFRC?.delegate = self
        }
        
        historyFRC?.performFetch { [weak self] in
            guard let self = self else { return }
            
            self.tableView.reloadData()
            self.updateEmptyPanelState()
        }
    }
    
    fileprivate func createEmptyStateOverview() -> UIView {
        let overlayView = UIView()
        overlayView.backgroundColor = .white
        
        return overlayView
    }
    
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = super.tableView(tableView, cellForRowAt: indexPath)
        configureCell(cell, atIndexPath: indexPath)
        return cell
    }
    
    func configureCell(_ _cell: UITableViewCell, atIndexPath indexPath: IndexPath) {
        guard let cell = _cell as? TwoLineTableViewCell else { return }
        
        if !tableView.isEditing {
            cell.gestureRecognizers?.forEach { cell.removeGestureRecognizer($0) }
            let lp = UILongPressGestureRecognizer(target: self, action: #selector(longPressedCell(_:)))
            cell.addGestureRecognizer(lp)
        }
        
        let site = frc!.object(at: indexPath)
        cell.backgroundColor = .clear
        cell.setLines(site.title, detailText: site.url)
        
        cell.imageView?.contentMode = .scaleAspectFit
        cell.imageView?.image = FaviconFetcher.defaultFaviconImage
        cell.imageView?.layer.borderColor = BraveUX.faviconBorderColor.cgColor
        cell.imageView?.layer.borderWidth = BraveUX.faviconBorderWidth
        cell.imageView?.layer.cornerRadius = 6
        cell.imageView?.layer.cornerCurve = .continuous
        cell.imageView?.layer.masksToBounds = true
        if let url = site.domain?.url?.asURL {
            cell.imageView?.loadFavicon(for: url)
        } else {
            cell.imageView?.clearMonogramFavicon()
            cell.imageView?.image = FaviconFetcher.defaultFaviconImage
        }
    }
    
    fileprivate func updateEmptyPanelState() {
        if  historyFRC?.fetchedObjectsCount == 0 {
            if emptyStateOverlayView.superview == nil {
                tableView.addSubview(emptyStateOverlayView)
                emptyStateOverlayView.snp.makeConstraints { make -> Void in
                    make.edges.equalTo(tableView)
                    make.size.equalTo(view)
                }
            }
        } else {
            emptyStateOverlayView.removeFromSuperview()
        }
    }
    
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = super.tableView(tableView, cellForRowAt: indexPath)
        configureCell(cell, atIndexPath: indexPath)
        
        return cell
    }
    
    func configureCell(_ _cell: UITableViewCell, atIndexPath indexPath: IndexPath) {
        guard let cell = _cell as? TwoLineTableViewCell else { return }
        
        if !tableView.isEditing {
            cell.gestureRecognizers?.forEach { cell.removeGestureRecognizer($0) }
            cell.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(longPressedCell(_:))))
        }
        
        guard let historyItem = historyFRC?.object(at: indexPath) else { return }
        
        cell.do {
            $0.backgroundColor = UIColor.clear
            $0.setLines(historyItem.title, detailText: historyItem.url)
            
            $0.imageView?.contentMode = .scaleAspectFit
            $0.imageView?.image = FaviconFetcher.defaultFaviconImage
            $0.imageView?.layer.borderColor = BraveUX.faviconBorderColor.cgColor
            $0.imageView?.layer.borderWidth = BraveUX.faviconBorderWidth
            $0.imageView?.layer.cornerRadius = 6
            $0.imageView?.layer.masksToBounds = true
            
            if let url = historyItem.domain?.asURL {
                cell.imageView?.loadFavicon(for: url)
            } else {
                cell.imageView?.clearMonogramFavicon()
                cell.imageView?.image = FaviconFetcher.defaultFaviconImage
            }
        }
    }
    
    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard let historyItem = historyFRC?.object(at: indexPath) else { return }
        
        if let historyURL = historyItem.url, let url = URL(string: historyURL) {
            dismiss(animated: true) {
                self.toolbarUrlActionsDelegate?.select(url: url, visitType: .typed)
            }
        }
        
        tableView.deselectRow(at: indexPath, animated: true)
    }
    
    @objc private func longPressedCell(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began,
              let cell = gesture.view as? UITableViewCell,
              let indexPath = tableView.indexPath(for: cell),
              let urlString = historyFRC?.object(at: indexPath)?.url else {
            return
        }
        
        presentLongPressActions(gesture, urlString: urlString, isPrivateBrowsing: isPrivateBrowsing)
    }
    
    func numberOfSections(in tableView: UITableView) -> Int {
        return historyFRC?.sectionCount ?? 0
    }
    
    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        return historyFRC?.titleHeader(for: section)
    }
    
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return historyFRC?.objectCount(for: section) ?? 0
    }
    
    func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        switch editingStyle {
            case .delete:
                guard let historyItem = historyFRC?.object(at: indexPath) else { return }
                
                historyItem.delete()
            default:
                break
        }
    }
}

// MARK: - HistoryV2FetchResultsDelegate

extension HistoryViewController: HistoryV2FetchResultsDelegate {
    
    func controllerWillChangeContent(_ controller: HistoryV2FetchResultsController) {
        tableView.beginUpdates()
    }
    
    func controllerDidChangeContent(_ controller: HistoryV2FetchResultsController) {
        tableView.endUpdates()
    }
    
    func controller(_ controller: HistoryV2FetchResultsController, didChange anObject: Any, at indexPath: IndexPath?, for type: NSFetchedResultsChangeType, newIndexPath: IndexPath?) {
        switch type {
            case .insert:
                if let indexPath = newIndexPath {
                    tableView.insertRows(at: [indexPath], with: .automatic)
                }
            case .delete:
                if let indexPath = indexPath {
                    tableView.deleteRows(at: [indexPath], with: .automatic)
                }
            case .update:
                if let indexPath = indexPath, let cell = tableView.cellForRow(at: indexPath) {
                    configureCell(cell, atIndexPath: indexPath)
                }
            case .move:
                if let indexPath = indexPath {
                    tableView.deleteRows(at: [indexPath], with: .automatic)
                }
                
                if let newIndexPath = newIndexPath {
                    tableView.insertRows(at: [newIndexPath], with: .automatic)
                }
            @unknown default:
                assertionFailure()
        }
        updateEmptyPanelState()
    }
    
    func controller(_ controller: HistoryV2FetchResultsController, didChange sectionInfo: NSFetchedResultsSectionInfo, atSectionIndex sectionIndex: Int, for type: NSFetchedResultsChangeType) {
        switch type {
            case .insert:
                let sectionIndexSet = IndexSet(integer: sectionIndex)
                self.tableView.insertSections(sectionIndexSet, with: .fade)
            case .delete:
                let sectionIndexSet = IndexSet(integer: sectionIndex)
                self.tableView.deleteSections(sectionIndexSet, with: .fade)
            default: break
        }
    }
    
    func controllerDidReloadContents(_ controller: HistoryV2FetchResultsController) {
        reloadData()
    }
}
