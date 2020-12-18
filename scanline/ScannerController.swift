//
//  ScanController.swift
//  scanline
//
//  Created by acordex on 12/7/20.
//  Copyright © 2020 Scott J. Kleper. All rights reserved.
//

import Foundation
import ImageCaptureCore
import CoreGraphics

protocol ScannerControllerDelegate: class {
    func scannerControllerDidFail(_ scannerController: ScannerController)
    func scannerControllerDidSucceed(_ scannerController: ScannerController)
}

class ScannerController: NSObject, ICScannerDeviceDelegate {
    let scanner: ICScannerDevice
    let configuration: ScanConfiguration
    let logger: Logger
    var scannedURLs = [URL]()
    weak var delegate: ScannerControllerDelegate?
    var desiredFunctionalUnitType: ICScannerFunctionalUnitType {
        return (configuration.config[ScanlineConfigOptionFlatbed] == nil) ?
            ICScannerFunctionalUnitType.documentFeeder :
            ICScannerFunctionalUnitType.flatbed
    }
    
    init(scanner: ICScannerDevice, configuration: ScanConfiguration, logger: Logger) {
        self.scanner = scanner
        self.configuration = configuration
        self.logger = logger
        
        super.init()

        self.scanner.delegate = self
    }
    
    func scan() {
        logger.verbose("Opening session with scanner")
        scanner.requestOpenSession()
    }
    
    // MARK: - ICDeviceDelegate  (added -spf)
    func device(_ device: ICDevice, didReceiveStatusInformation status: [ICDeviceStatus : Any]) {
        logger.verbose("device status change \(status)")
    }
    
    // MARK: - ICScannerDeviceDelegate

    // added spf for in-memory transfer
    /* Tells the client when the scanner receives the requested scan progress notification and a band of data is sent for each notification received.
       In memory transfer mode, this method sends a band of the size selected by the client using the maxMemoryBandSize property.
     */
    func scannerDevice(_ scanner: ICScannerDevice, didScanTo data: ICScannerBandData) {
        
        let buffer = data.dataBuffer
        let dsr = data.dataStartRow  // this is critical value: value is 0 on start of new page
        let isNewPage = dsr == 0
        let dnr = data.dataNumRows  // this is number of rows in the buffer e.g. 102 until final band for page = 18
        let ds = data.dataSize      // ds and cnt are idential values
        //let fiw = data.fullImageWidth // 1275
        //let fih = data.fullImageHeight // 1650; fixed
        let cnt = buffer?.count
        
        // https://stackoverflow.com/questions/22859289/how-to-create-an-image-from-data-received-from-scanner
        let color = CGColorSpaceCreateDeviceGray();
        //   if ([data pixelDataType] == ICScannerPixelDataTypeRGB) color = CGColorSpaceCreateDeviceRGB();
        let nsData = NSData(data: buffer!)
   
        let image = CGImage(width: data.fullImageWidth, height: data.fullImageHeight, bitsPerComponent: data.bitsPerComponent, bitsPerPixel: data.bitsPerPixel, bytesPerRow: data.bytesPerRow, space: color, bitmapInfo: CGBitmapInfo(rawValue: 0), provider: CGDataProvider(data: CFDataCreate(nil, nsData.bytes.assumingMemoryBound(to: UInt8.self), data.dataSize)!)!, decode: nil, shouldInterpolate: false, intent: CGColorRenderingIntent(rawValue: 0)!)
        let size = NSMakeSize(CGFloat(data.fullImageWidth), CGFloat(data.fullImageHeight))
        let finImage = NSImage(cgImage: image!, size: size)
        //NSImage *finImage = [[NSImage alloc] initWithCGImage:image size:NSMakeSize([data fullImageWidth], [data fullImageHeight])];
        logger.verbose("didScanTo received \(cnt ?? 0) bytes; dsr \(dsr) dnr \(dnr) dsz \(ds)   ")
         
    }
    
    func device(_ device: ICDevice, didEncounterError error: Error?) {
        logger.verbose("didEncounterError: \(error?.localizedDescription ?? "[no error]")")
        delegate?.scannerControllerDidFail(self)
    }
    
    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {
        logger.verbose("didCloseSessionWithError") //\(error.localizedDescription)")
        delegate?.scannerControllerDidFail(self)
    }
    
    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        logger.verbose("didOpenSessionWithError: \(error?.localizedDescription ?? "[no error]")")
        
        guard error == nil else {
            logger.log("Error received while attempting to open a session with the scanner.")
            delegate?.scannerControllerDidFail(self)
            return
        }
    }
    
    func didRemove(_ device: ICDevice) {
    }
    
    func deviceDidBecomeReady(_ device: ICDevice) {
        logger.verbose("deviceDidBecomeReady")
        selectFunctionalUnit()
    }
    
    func scannerDevice(_ scanner: ICScannerDevice, didSelect functionalUnit: ICScannerFunctionalUnit, error: Error?) {
        logger.verbose("didSelectFunctionalUnit: \(functionalUnit) error: \(error?.localizedDescription ?? "[no error]")")
        
        // NOTE: Despite the fact that `functionalUnit` is not an optional, it still sometimes comes in as `nil` even when `error` is `nil`
        if functionalUnit.type == self.desiredFunctionalUnitType {
            configureScanner()
            logger.log("Starting scan...")
            scanner.requestScan()
        }
    }

    func scannerDevice(_ scanner: ICScannerDevice, didScanTo url: URL) {
        logger.verbose("didScanTo \(url)")
        
        scannedURLs.append(url)
    }
    
    func scannerDevice(_ scanner: ICScannerDevice, didCompleteScanWithError error: Error?) {
        logger.verbose("didCompleteScanWithError \(error?.localizedDescription ?? "[no error]")")
        
        guard error == nil else {
            logger.log("ERROR: \(error!.localizedDescription)")
            delegate?.scannerControllerDidFail(self)
            return
        }

        if self.configuration.config[ScanlineConfigOptionBatch] != nil {
            logger.log("Press RETURN to scan next page or S to stop")
            let userInput = String(format: "%c", getchar())
            if !"sS".contains(userInput) {
                logger.verbose("Continuing scan")
                scanner.requestScan()
                return
            }
        }

        let outputProcessor = ScanlineOutputProcessor(urls: self.scannedURLs, configuration: configuration, logger: logger)
        if outputProcessor.process() {
            delegate?.scannerControllerDidSucceed(self)
        } else {
            delegate?.scannerControllerDidFail(self)
        }
    }
    
    // MARK: Private Methods
    
    fileprivate func selectFunctionalUnit() {
        scanner.requestSelect(self.desiredFunctionalUnitType)
    }
    
    fileprivate func configureScanner() {
        logger.verbose("Configuring scanner")
        
        let functionalUnit = scanner.selectedFunctionalUnit
      
        if functionalUnit.type == .documentFeeder {
            configureDocumentFeeder()
        } else {
            configureFlatbed()
        }
        
        let desiredResolution =  Int(configuration.config[ScanlineConfigOptionResolution] as? String ?? "200") ?? 200
        if let resolutionIndex = functionalUnit.supportedResolutions.integerGreaterThanOrEqualTo(desiredResolution) {
            functionalUnit.resolution = resolutionIndex
        }
        
        if configuration.config[ScanlineConfigOptionMono] != nil {
            functionalUnit.pixelDataType = .BW
            functionalUnit.bitDepth = .depth1Bit
        } else {
            functionalUnit.pixelDataType = .RGB
            functionalUnit.bitDepth = .depth8Bits
        }
       
        scanner.transferMode = .fileBased
        //scanner.transferMode = .memoryBased  // change -spf
        let mbs = scanner.maxMemoryBandSize
      
      
        scanner.downloadsDirectory = URL(fileURLWithPath: NSTemporaryDirectory())
        scanner.documentName = "Scan"
        
        if (true) { //configuration.config[ScanlineConfigOptionTIFF] != nil {
            scanner.documentUTI = kUTTypeTIFF as String
        } else {
            scanner.documentUTI = kUTTypeJPEG as String
        }
    }

    fileprivate func configureDocumentFeeder() {
        logger.verbose("Configuring Document Feeder")

        guard let functionalUnit = scanner.selectedFunctionalUnit as? ICScannerFunctionalUnitDocumentFeeder else { return }
        
        functionalUnit.documentType = { () -> ICScannerDocumentType in
            if configuration.config[ScanlineConfigOptionLegal] != nil {
                return .typeUSLegal
            }
            if configuration.config[ScanlineConfigOptionA4] != nil {
                return .typeA4
            }
            return .typeUSLetter
        }()
      
        
        functionalUnit.duplexScanningEnabled = (configuration.config[ScanlineConfigOptionDuplex] != nil)
    }
    
    fileprivate func configureFlatbed() {
        logger.verbose("Configuring Flatbed")
        
        guard let functionalUnit = scanner.selectedFunctionalUnit as? ICScannerFunctionalUnitFlatbed else { return }

        functionalUnit.measurementUnit = .inches
        let physicalSize = functionalUnit.physicalSize
        functionalUnit.scanArea = NSMakeRect(0, 0, physicalSize.width, physicalSize.height)
    }
}
