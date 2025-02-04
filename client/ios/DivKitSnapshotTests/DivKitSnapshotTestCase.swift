import XCTest

import BaseUI
import CommonCore
import DivKit
import LayoutKit
import Networking

let testCardId = "test_card_id"
let testDivCardId = DivCardID(rawValue: testCardId)

class DivKitSnapshotTestCase: XCTestCase {
  #if UPDATE_SNAPSHOTS
  final var mode = TestMode.update
  #else
  final var mode = TestMode.verify
  #endif
  
  final var subdirectory = ""
  final var rootDirectory = "json"

  final func testDivs(
    _ fileName: String,
    testName: String = #function,
    customCaseName: String? = nil,
    imageHolderFactory: ImageHolderFactory? = nil,
    blocksState: BlocksState = [:]
  ) {
    guard let jsonData = jsonData(fileName: fileName, subdirectory: rootDirectory + "/" + subdirectory),
          let dictionary = jsonDict(data: jsonData) else {
      XCTFail("Invalid json: \(fileName)")
      return
    }

    let divKitComponents = DivKitComponents(
      imageHolderFactory: imageHolderFactory ?? makeImageHolderFactory(),
      updateCardAction: nil,
      urlOpener: { _ in }
    )
    for (path, state) in blocksState {
      divKitComponents.blockStateStorage.setState(path: path, state: state)
    }

    let dataWithErrors = loadDivData(dictionary: dictionary, divKitComponents: divKitComponents)
    guard let data = dataWithErrors.0 else {
      XCTFail(
        "Data could not be created from json \(fileName), try to set breakpoint on the following errors: \(dataWithErrors.1.map { type(of: $0) })"
      )
      return
    }

    do {
      try testDivs(
        data: data,
        divKitComponents: divKitComponents,
        caseName: customCaseName ??
          (fileName.removingFileExtension + "_" + testName.extractingDescription),
        steps: loadSteps(dictionary: dictionary)
      )
    } catch {
      XCTFail("Testing div failed with error: \(error.localizedDescription)")
    }
  }

  private func loadSteps(dictionary: [String: Any]) throws -> [TestStep]? {
    return try? dictionary
      .getOptionalArray(
        "steps",
        transform: { try TestStep(dictionary: $0 as [String: Any]) }
      ).unwrap()
  }

  private func loadDivData(dictionary: [String: Any], divKitComponents: DivKitComponents) -> (DivData?, [Error]) {
    var errors = [Error]()
    do {
      let divData = try dictionary.getOptionalField("div_data") ?? dictionary
      let result = try divKitComponents.parseDivDataWithTemplates(divData, cardId: testDivCardId)
      if let data = result.value {
        return (data, errors)
      } else {
        errors += result.getErrorsOrWarnings()
      }
    } catch {
      errors.append(error)
    }
    return (nil, errors)
  }

  private func testDivs(
    data: DivData,
    divKitComponents: DivKitComponents,
    caseName: String,
    steps: [TestStep]? = nil
  ) throws {
    if let steps = steps {
      for (index, step) in steps.enumerated() {
        step.divActions?.forEach { divAction in
          divKitComponents.actionHandler.handle(
            divAction,
            cardId: testDivCardId,
            source: .custom,
            urlOpener: divKitComponents.urlOpener
          )
        }
        try checkSnapshots(
          data: data,
          divKitComponents: divKitComponents,
          caseName: caseName,
          stepName: step.name ?? "step\(index)"
        )
      }
    } else {
      try checkSnapshots(
        data: data,
        divKitComponents: divKitComponents,
        caseName: caseName
      )
    }
  }

  private func checkSnapshots(
    data: DivData,
    divKitComponents: DivKitComponents,
    caseName: String,
    stepName: String? = nil
  ) throws {
    let currentScale = UIScreen.main.scale
    let devices = ScreenSize.portrait.filter { $0.scale == currentScale }
    try devices.forEach { device in
      var view = try makeDivView(
        data: data,
        divKitComponents: divKitComponents,
        size: device.size
      )
      if view.bounds.isEmpty {
        view = makeEmptyView()
      }
      guard let image = view.makeSnapshot() else {
        throw DivTestingErrors.snapshotCouldNotBeCreated
      }
      let referenceUrl = referenceFileURL(
        device: device,
        caseName: caseName,
        stepName: stepName
      )

      SnapshotTestKit.testSnapshot(
        image,
        referenceURL: referenceUrl,
        diffDirPath: referenceUrl.path,
        mode: mode
      )
      checkSnapshotsForAnotherScales(currentScale, caseName: caseName, stepName: stepName)
    }
  }

  private func checkSnapshotsForAnotherScales(
    _ scale: CGFloat,
    caseName: String,
    stepName: String?
  ) {
    let scaleToCheck: CGFloat = scale == 2 ? 3 : 2
    let devices = ScreenSize.portrait.filter { $0.scale == scaleToCheck }
    let fileManager = FileManager.default
    devices.forEach { device in
      let referenceUrl = referenceFileURL(
        device: device,
        caseName: caseName,
        stepName: stepName
      )
      let path = referenceUrl.path
      XCTAssertTrue(
        fileManager.fileExists(atPath: path),
        "Don't forget to add file with scale \(scaleToCheck) and path \(path)"
      )
    }
  }

  private func referenceFileURL(
    device: ScreenSize,
    caseName: String,
    stepName: String?
  ) -> URL {
    let referencesURL = URL(
      fileURLWithPath: ReferenceSet.path,
      isDirectory: true
    ).appendingPathComponent(subdirectory)
    var stepDescription = ""
    if let stepName = stepName {
      stepDescription = "_" + stepName
    }
    let fileName = caseName + "_\(Int(device.size.width))" + device.scale.imageSuffix + "\(stepDescription).png"
    return referencesURL.appendingPathComponent(fileName, isDirectory: false)
  }

  private func makeDivView(
    data: DivData,
    divKitComponents: DivKitComponents,
    size: CGSize
  ) throws -> UIView {
    guard let block = data.makeBlock(
      divKitComponents: divKitComponents
    ) else {
      throw DivTestingErrors.blockCouldNotBeCreatedFromData
    }
    let blockSize = block.size(forResizableBlockSize: size)
    let divView = block.makeBlockView()
    divView.frame = CGRect(origin: .zero, size: blockSize)
    divView.layoutIfNeeded()
    return divView
  }
}

private func jsonData(fileName: String, subdirectory: String) -> Data? {
  testBundle.url(
    forResource: fileName,
    withExtension: nil,
    subdirectory: subdirectory
  ).flatMap { try? Data(contentsOf: $0) }
}

private func jsonDict(data: Data) -> [String: Any]? {
  (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

private func makeEmptyView() -> UIView {
  let label = UILabel()
  label.text = "<empty view>"
  label.frame = CGRect(origin: .zero, size: label.intrinsicContentSize)
  return label
}

private enum DivTestingErrors: LocalizedError {
  case blockCouldNotBeCreatedFromData
  case snapshotCouldNotBeCreated

  var errorDescription: String? {
    switch self {
    case .blockCouldNotBeCreatedFromData:
      return "Block could not be created from data"
    case .snapshotCouldNotBeCreated:
      return "Snapshot could not be created from view"
    }
  }
}

extension String {
  fileprivate var extractingDescription: String {
    let removedPrefix = "test_"
    let removedSuffix = "()"
    return String(self[removedPrefix.count..<(count - removedSuffix.count)])
  }

  var removingFileExtension: String {
    guard let dotIndex = firstIndex(of: ".") else {
      return self
    }
    return String(self[startIndex..<dotIndex])
  }
}

extension CGFloat {
  fileprivate var imageSuffix: String {
    self == 1 ? "" : "@\(Int(self))x"
  }
}

private let testBundle = Bundle(for: DivKitSnapshotTestCase.self)

extension DivData {
  fileprivate func makeBlock(
    divKitComponents: DivKitComponents
  ) -> Block? {
    let context = divKitComponents.makeContext(
      cardId: testDivCardId,
      cachedImageHolders: []
    )
    do {
      return try makeBlock(context: context)
    } catch {
      XCTFail("Failure while making block: \(error)")
      return nil
    }
  }
}

extension ImageHolderFactory {
  static let placeholderOnly = ImageHolderFactory(
    make: { _, placeholder in
      switch placeholder {
      case let .image(image)?:
        return image
      case let .color(color)?:
        return ColorHolder(color: color)
      case .none:
        return NilImageHolder()
      }
    }
  )
}

private var reportedURLStrings = Set<String>()

private func makeImageHolderFactory() -> ImageHolderFactory {
  ImageHolderFactory(
    make: { url, _ in
      guard let url = url else {
        XCTFail("Predefined images not supported in tests")
        return UIImage()
      }

      if let image = UIImage(named: url.lastPathComponent, in: testBundle, compatibleWith: nil) {
        return image
      }

      let absoluteString = url.absoluteString
      if !reportedURLStrings.contains(absoluteString) {
        XCTFail(
          "Loading images from network is prohibited in tests. You need to load image from "
            + absoluteString + " and add it to Images.xcassets in testing bundle"
        )
        reportedURLStrings.insert(absoluteString)
      }

      return UIImage()
    }
  )
}

private struct TestStep {
  let name: String?
  let divActions: [DivActionBase]?

  public init(dictionary: [String: Any]) throws {
    let expectedScreenshot: String? = try dictionary.getOptionalField("expected_screenshot")
    name = expectedScreenshot?.replacingOccurrences(of: ".png", with: "")
    divActions = try? dictionary.getOptionalArray("div_actions", transform: { (actionDictionary: [String: Any]) -> DivActionBase in
      try DivTemplates.empty.parseValue(type: DivActionTemplate.self, from: actionDictionary).unwrap()
    }).unwrap()
  }
}
