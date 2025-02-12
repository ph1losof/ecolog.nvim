import { workspace } from 'coc.nvim';
import { EcologCompletionProvider } from './index';

jest.mock('coc.nvim', () => ({
  workspace: {
    nvim: {
      call: jest.fn(),
      eval: jest.fn(),
    },
  },
}));

describe('EcologCompletionProvider', () => {
  let provider: EcologCompletionProvider;

  beforeEach(() => {
    provider = new EcologCompletionProvider();
    jest.clearAllMocks();
  });

  it('should return empty array when ecolog is not available', async () => {
    (workspace.nvim.call as jest.Mock).mockResolvedValueOnce([false, null]);

    const result = await provider.provideCompletionItems(
      {} as any,
      { line: 0, character: 0 },
      {} as any,
      {} as any
    );

    expect(result).toEqual([]);
  });

  it('should return empty array when no env vars are available', async () => {
    (workspace.nvim.call as jest.Mock)
      .mockResolvedValueOnce([true, {}])
      .mockResolvedValueOnce({ provider_patterns: { cmp: true } })
      .mockResolvedValueOnce({});

    const result = await provider.provideCompletionItems(
      {} as any,
      { line: 0, character: 0 },
      {} as any,
      {} as any
    );

    expect(result).toEqual([]);
  });

  it('should return completion items for available env vars', async () => {
    const mockEnvVars = {
      TEST_VAR: {
        value: 'test-value',
        type: 'string',
        source: '.env',
        comment: 'Test variable',
      },
    };

    (workspace.nvim.call as jest.Mock)
      .mockResolvedValueOnce([true, {}])
      .mockResolvedValueOnce({ provider_patterns: { cmp: false } })
      .mockResolvedValueOnce(mockEnvVars)
      .mockResolvedValueOnce([])
      .mockResolvedValueOnce({
        is_enabled: () => false,
        mask_value: (val: string) => val,
      });

    const result = await provider.provideCompletionItems(
      {
        getText: () => 'TEST_',
      } as any,
      { line: 0, character: 5 },
      {} as any,
      {} as any
    );

    expect(result).toHaveLength(1);
    expect(result[0].label).toBe('TEST_VAR');
    expect(result[0].detail).toBe('.env');
  });
}); 